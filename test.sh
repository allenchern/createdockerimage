#!/usr/bin/env bash

GET_PIP_URL="https://bootstrap.pypa.io/get-pip.py"
AWS_IAM_AUTH_URL="https://amazon-eks.s3-us-west-2.amazonaws.com/1.14.6/2019-08-22/bin/linux/amd64/aws-iam-authenticator"
KUBECTL_VERSION=`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`
KUBECTL_URL="https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"
HELM_VER=$(curl -sSL https://github.com/kubernetes/helm/releases | sed -n '/Latest release<\/a>/,$p' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
HELM_VER="v3.1.0"
HELM_TARBALL="helm-"$HELM_VER"-linux-amd64.tar.gz"
HELM_URL="https://get.helm.sh/$HELM_TARBALL"
SISENSE_TARBALL="sisense_linux_latest.tar.gz"
SISENSE_DOWNLOAD_URL="https://data.sisense.com/linux/$SISENSE_TARBALL"
UPDATE=false
MONITORING=false
DNS_NAME=$1

echo "Build start at"
date
echo ""

#AWS CLI VALIDATION
echo "Checking AWS CLI Access..."
aws ec2 describe-instances --max-items 1 >> /dev/null
HAS_AWS_ACCESS=$?
if [ "$HAS_AWS_ACCESS" -ne 0 ]
then
  echo "ERROR: AWS CLI not installed or properly configured! exiting..."
  exit 1
fi
echo "Done!"
echo ""

#SSH KEY
echo "Configuring SSH Key..."
RSA_KEY="$HOME/sisense.rsa"
rm -rf $RSA_KEY*
ssh-keygen -b 2048 -t rsa -f $RSA_KEY -q -N ""
SSH_STAT=$?
if [ "$SSH_STAT" -ne 0 ]
then
  echo "ERROR: Failed generating rsa key! exiting..."
  exit 1
else
  ls $RSA_KEY
fi
cat $RSA_KEY.pub >> $HOME/.ssh/authorized_keys
echo "Done!"
echo ""

#AWS-IAM-AUTHENTICATOR
echo "Configuring aws-iam-authenticator..."
which aws-iam-authenticator
HAS_AWS_IAM_AUTH=`echo $?`
if [ "$HAS_AWS_IAM_AUTH" -ne 0 ]
then
  curl -O $AWS_IAM_AUTH_URL
  chmod +x ./aws-iam-authenticator
  sudo mv ./aws-iam-authenticator /usr/local/bin
  aws-iam-authenticator version
  AWS_IAM_AUTH_STAT=$?
  if [ "$AWS_IAM_AUTH_STAT" -ne 0 ]
  then
    echo "ERROR: Failed configuring aws-iam-authenticator! exiting..."
    exit 1
  fi
fi
echo "Done!"
echo ""

#KUBECTL
echo "Installing kubectl..."
which kubectl
HAS_KUBECTL=$?
if [ "$HAS_KUBECTL" -ne 0 ]
then
  curl -O $KUBECTL_URL
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
  which kubectl
  HAS_KUBECTL=$?
  if [ "$HAS_KUBECTL" -ne 0 ]
  then
    echo "ERROR: Failed installing kubectl! exiting..."
    exit 1
  fi
fi
echo "Done!"
echo ""

echo "Configuring kubectl..."
SISENSE_CLUSTER=`aws eks list-clusters | grep sisense | head -n 1 | tr -d '[:space:]"'`
AWS_REGION=`aws configure get region`
HAS_KUBECONTEXT=`kubectl config get-contexts | grep $SISENSE_CLUSTER`
if [ -z "$HAS_KUBECONTEXT" ]
then
  aws eks update-kubeconfig --name $SISENSE_CLUSTER --region $AWS_REGION
  HAS_KUBECONFIG=$?
  if [ "$HAS_KUBECONFIG" -ne 0 ]
  then
    echo "ERROR: Failed retrieving kubeconfig from AWS! exiting..."
    exit 1
  fi
else
  kubectl config get-contexts | grep $SISENSE_CLUSTER
fi
echo "Done!"
echo ""

#HELM AND TILLER
echo "Installing Helm and Tiller..."
which helm && helm version
HAS_HELM=$?
if [ "$HAS_HELM" -ne 0 ]
then
  curl -O $HELM_URL
  tar -xf $HELM_TARBALL
  sudo mv ./linux-amd64/helm /usr/local/bin;
  which helm && helm version
  HAS_HELM=$?
  if [ "$HAS_HELM" -ne 0 ]
  then
    echo "ERROR: Failed installing helm and tiller! exiting..."
    exit 1
  fi
fi
echo "Done!"
echo ""

echo "Configuring Helm and Tiller..."
kubectl get clusterrolebinding tiller-cluster-rule
HAS_TILLER_RULE=$?
if [ "$HAS_TILLER_RULE" -ne 0 ]
then
  kubectl create serviceaccount --namespace kube-system tiller
  kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
  kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
  helm init --service-account tiller --upgrade
  kubectl get clusterrolebinding tiller-cluster-rule
  HAS_TILLER_RULE=$?
  if [ "$HAS_TILLER_RULE" -ne 0 ]
  then
    echo "ERROR: Failed configuring helm and tiller! exiting..."
    exit 1
  fi
fi
echo "Done!"
echo ""

#SISENSE
echo "Installing Latest Sisense Build..."
curl -O $SISENSE_DOWNLOAD_URL
tar -xf $SISENSE_TARBALL >> /dev/null 2>&1

SISENSE_DIR=`find ./ -maxdepth 1  -type d -name "sisense-L*" | tail -n 1`
echo "Sisense build version is: "$SISENSE_DIR
if [ -z "$SISENSE_DIR" ]
then
  echo "ERROR: Failed installing latest sisense build! exiting..."
  exit 1
fi
echo "Done!"
echo ""

echo "Configuring sisense cloud_config.yaml..."
USER=`whoami`
EFS_ID=`aws efs describe-file-systems --max-items 1 | grep 'FileSystemId' | awk -F\" '{print $4}'` #BUG: currently efs storge has no name to filter
WORKER_NODES=`kubectl get nodes | grep sisense | awk '{print $1}'`

if [ ! -z "$EFS_ID" ] && [ ! -z "$WORKER_NODES" ]; then
	echo "k8s_nodes:" > $SISENSE_DIR/cloud_config.yaml
	for WORKER in `echo $WORKER_NODES`; do
		echo "  - { node: $WORKER, roles: 'application, query, build' }" >> $SISENSE_DIR/cloud_config.yaml
	done

	cat >> $SISENSE_DIR/cloud_config.yaml <<EOF
offline_installer: false
#docker_registry: ""
update: $UPDATE
is_kubernetes_cloud: true
kubernetes_cluster_name: '$SISENSE_CLUSTER'
kubernetes_cluster_location: '$AWS_REGION'
kubernetes_cloud_provider: 'aws'
cloud_load_balancer: true
application_dns_name: '$DNS_NAME'
linux_user: '$USER'
ssh_key: '$RSA_KEY'
storage_type: 'efs'
nfs_server: ''
nfs_path: ''
efs_file_system_id: '$EFS_ID'
efs_aws_region: '$AWS_REGION'
fsx_file_system_id: ''
fsx_region: ''
sisense_disk_size: 150
mongodb_disk_size: 20
zookeeper_disk_size: 2
namespace_name: sisense
gateway_port: 30845
is_ssl: false
ssl_key_path: ''
ssl_cer_path: ''
internal_monitoring: $MONITORING
external_monitoring: $MONITORING
uninstall_sisense: false
remove_user_data: false
EOF
	cat $SISENSE_DIR/cloud_config.yaml
fi
echo "Done!"
echo ""

echo "Run sisense.sh..."
cd $SISENSE_DIR
./sisense.sh cloud_config.yaml -y
echo "Build Ended at"
date

exit 0
© 2020 GitHub, Inc.
Terms
Privacy
Security
Status
Help
Contact GitHub
Pricing
API
Training
Blog
About

