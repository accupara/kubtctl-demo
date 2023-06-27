#!/bin/bash

export NAMESPACE=default
export ENABLE_AWS=1
export AWS_ACCOUNT=
export AWS_REGION=
export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=
export AWS_ECR_SECRET_PREFIX=regcred
export K8S_PROXY_PORT=16181
export CLUSTER_MOUNTS= #(<src folder 1>:<dst folder1>,...) /opt/mongodb/data:/mongodb/data
export CLUSTER_PORT_FORWARDS="app.kubernetes.io/name=my-demo-app,app.kubernetes.io/instance=my-demo-chart:16190 app.kubernetes.io/name=my-demo-app,app.kubernetes.io/instance=my-demo-chart:16191"
export KIND_WORKERS=0


# my-demo-chart demo-chart/ --values demo-chart/values.yaml
export K8S_ENC_FILES=
export K8S_VAR_FILES=demo-chart/values.yaml
export K8S_CHART_NAME=my-demo-chart
export K8S_CHART_REFERENCE=./demo-chart/

all_cmounts=()
KIND_EXE="/root/go/bin/kind"
print_sep() {
        printf '%.s─' $(seq 1 $(tput cols))
        echo
}

print_title() {
        print_sep
        echo $* " @ `date`"
        print_sep
}

install_monit() {
	print_title "Installing monit"
	sudo apt-get update -y
	sudo apt install -y monit
	cat <<EOF > /etc/monit/conf.d/custom.settings
set daemon 5
set httpd port 2812 and
  allow localhost
  allow admin:monit
EOF
}

start_monit() {
	print_title "Starting monit"
	monit -t
	echo Status:
	monit
	monit status
}

setup_minikube_cluster_mounts() {
	if [ "${CLUSTER_MOUNTS}" == "" ]; then
		echo "No cluster mounts specified"
		return
	fi
        for cmount in `echo ${CLUSTER_MOUNTS} | tr "," " "`; do
		if [ "${mount_string}" == "" ]; then
			mount_string="--mount"
		fi

                srcDir=`echo ${cmount} | cut -d ":" -f 1`
                mkdir -p ${srcDir}
		mount_string=${mount_string}" --mount-string ${cmount}"
        done
        print_title "Cluster mount string: " ${mount_string}
	return ${mount_string}
}

start_minikube() {
	print_title "Normalizing persistent mounts."
	mount_string=setup_minikube_cluster_mounts
        print_title "Starting minikube"
        minikube start --force ${mount_string}
}

start_kind(){
        print_title "creating kind config"
        cat << EOF > /tmp/kind.config.mine
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
    - hostPath: /opt/clusterdata
      containerPath: /mongodb/data
EOF
        for i in `seq 1 ${KIND_WORKERS}`; do
                echo "- role: worker" >> /tmp/kind.config.mine
        done
        cat /tmp/kind.config.mine
        print_title "Starting kind cluster"
        ${KIND_EXE} create cluster --config /tmp/kind.config.mine
        sleep 10
        kubectl get nodes
        kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
        kubectl taint nodes --all node.kubernetes.io/not-ready:NoSchedule-
        kubectl get nodes
}


check_helm_plugins() {
        print_title "Validating helm secrets plugin"
        helm plugin list
        print_title "Installing helm secrets"
        helm plugin install https://github.com/zendesk/helm-secrets
        helm plugin list
}

setup_aws_credentials() {
        print_title "Setting up aws credentials file from environment"

        if [ "$AWS_ACCESS_KEY_ID" == "" -o "$AWS_SECRET_ACCESS_KEY" == "" ]; then
                echo "Could not find aws credentials in environment."
                return
        fi
        mkdir -p ~/.aws
        rm -f ~/.aws/credentials
        cat << EOF >> ~/.aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF

        cat ~/.aws/credentials
}

create_k8s_secrets() {
        print_title "Creating k8s secrets."
	if [ "${AWS_REGION}" == "" -o "${AWS_ACCOUNT}" == "" -o "{AWS_ECR_SECRET_PREFIX}" == "" -o "${NAMESPACE}" == "" ]; then
		echo "Could not create AWS ECR secret, as it is missing one or more of the following fields."
		echo "AWS_REGION | AWS_ACCOUNT | AWS_ECR_SECRET_PREFIX | NAMESPACE"
		return
	fi

        kubectl create secret docker-registry ${AWS_ECR_SECRET_PREFIX}-${AWS_REGION} \
                --docker-server=${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com \
                --docker-username=AWS \
                --docker-password=$(/usr/local/bin/aws ecr get-login-password) \
                --namespace=${NAMESPACE}
}

install_chart() {
        print_title "Installing or upgrading helm chart."
        echo "Using namespace $NAMESPACE"
	for f in `echo ${K8S_ENC_FILES} | tr "," " "`; do
		echo "Decrypting $f"
		helm secrets dec $f
		helm_file_args=${helm_file_args}" -f ${f}.dec"
	done
	for f in `echo ${K8S_VAR_FILES} | tr "," " "`; do
		echo "Adding $f"
		helm_file_args=${helm_file_args}" -f ${f}"
	done
        helm upgrade --install --namespace $NAMESPACE \
                --set global.namespace="$NAMESPACE" \
		${helm_file_args} \
                ${K8S_CHART_NAME} ${K8S_CHART_REFERENCE}
	sleep 10
	kubectl get pods
}

setup_cluster_access_proxy() {
        print_title "Setting up cluster control proxy to port ${K8S_PROXY_PORT}."
        kubectl proxy --port ${K8S_PROXY_PORT} --address 0.0.0.0 --accept-hosts=".*"
}

setup_port_frowards() {
        print_title "Setting up required port forwards."
	i=0
        for cmount in ${CLUSTER_PORT_FORWARDS}; do
                appLabel=`echo ${cmount} | cut -d ":" -f 1`
		targetPort=`echo ${cmount} | cut -d ":" -f 2`

		POD_NAME=$(kubectl get pods --namespace ${NAMESPACE} -l "${appLabel}" -o jsonpath="{.items[0].metadata.name}")
		CONTAINER_PORT=$(kubectl get pod --namespace ${NAMESPACE} $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")

		echo "Mapping: ${appLabel} pod: ${POD_NAME} container_port: ${CONTAINER_PORT} hostport: ${targetPort}"
		if [ "$i" == "0" ]; then
			echo "Starting new tmux session"
			/usr/bin/tmux new-session -d -t portforwards -c bash
		else
			echo "Adding a horizontal split in tmux"
			/usr/bin/tmux split-window -t portforwards -h bash
		fi

		echo "  Creating port forward script"
		cat <<EOF > /tmp/portforward.${targetPort}.sh
#!/bin/bash
set -m
sudo kubectl --namespace ${NAMESPACE} port-forward --address 0.0.0.0  pod/$POD_NAME $targetPort:$CONTAINER_PORT &
pid=\$!
jobs -l
echo \$pid > /tmp/portforward.${targetPort}.pid
fg %1
EOF
		chmod a+x /tmp/portforward.${targetPort}.sh

		echo "  Configuring monit to monitor the port forwarding"
		cat <<EOF > /etc/monit/conf.d/portforward.${targetPort}
check process pf.${targetPort} with pidfile /tmp/portforward.${targetPort}.pid
  start program = "/usr/bin/tmux send -t portforwards:0.$i /tmp/portforward.${targetPort}.sh C-m"
  stop program = "/usr/bin/sleep 0.1"
EOF
		i=$((i+1))
        done
}

waitfor_pod_ready() {
        echo "Waiting for pod $1 to be ready"
        kubectl wait --timeout=2400s --for=condition=ready pod -l $1
}

install_monit
if [ "$1" == "kind" ]; then
	start_kind
else
	start_minikube
fi

check_helm_plugins
setup_aws_credentials
create_k8s_secrets
install_chart
setup_port_frowards
sleep 30 # wait for pods to come up?
start_monit
setup_cluster_access_proxy
#waitfor_pod_ready <label here>
