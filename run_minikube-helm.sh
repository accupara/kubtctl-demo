#!/usr/bin/env sh

minikube start --force

echo "======================= Running helm ==========================="
# wget https://get.helm.sh/helm-v3.9.2-linux-amd64.tar.gz
# tar -zxvf helm-v3.9.2-linux-amd64.tar.gz
# cp linux-amd64/helm /usr/local/bin
date
helm install --wait my-demo-chart demo-chart/ --values demo-chart/values.yaml
date

echo "==================="
echo "Nodes:"
kubectl get nodes
echo "Pods:"
kubectl get pods
echo "Services:"
kubectl get services
echo "==================="


#export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services my-demo-chart)
#export NODE_IP=$(kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}")
#echo http://$NODE_IP:$NODE_PORT
export POD_NAME=$(kubectl get pods --namespace default -l "app.kubernetes.io/name=my-demo-app,app.kubernetes.io/instance=my-demo-chart" -o jsonpath="{.items[0].metadata.name}")
export CONTAINER_PORT=$(kubectl get pod --namespace default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
echo "Visit http://127.0.0.1:8080 to use your application"
kubectl --namespace default port-forward --address 0.0.0.0  $POD_NAME 8080:$CONTAINER_PORT

echo "Running curl now..."
curl -v -k -i http://127.0.0.1:8080
ret=$?
echo "=================================="
if [ "$ret" != "0" ]
then
	echo "NGINX Connection successful."
else
	echo "NGINX Connection unsuccesful."
fi
exit $ret
