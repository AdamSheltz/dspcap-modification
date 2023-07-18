#!/bin/bash
# Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment. 
# THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, 
# INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.
# We grant You a nonexclusive, royalty-free right to use and modify the Sample Code and to reproduce and distribute the 
# object code form of the Sample Code, provided that. You agree: (i) to not use Our name, logo, or trademarks to market Your 
# software product in which the Sample Code is embedded; (ii) to include a valid copyright notice on Your software product in 
# which the Sample Code is embedded; and (iii) to indemnify, hold harmless, and defend Us and Our suppliers from and against
# any claims or lawsuits, including attorneys’ fees, that arise or result from the use or distribution of the Sample Code

set -x 
starttime=$(date -u +%Y-%m-%dT%H_%M%s)
#Create unique string 
UNIQID=$(tr -dc '[:lower:][:digit:]' </dev/urandom | fold -w 12 | head -n 1)
STORAGEACCOUNT="$1$UNIQID"
RESOURCEGROUP="$1"
LOCATION="eastus"
SECRETNAME="$STORAGEACCOUNT-secret"
SHARENAME="debug"


mkdir -p $RESOURCEGROUP

function create_resource_group() {
	now=$(date -u +%Y-%m-%dT%H_%M%s)
	echo "$starttime $now -  ${FUNCNAME[0]}"

	#Check to make sure that the resource group does not exist
	if ! az group show --resource-group $RESOURCEGROUP /dev/null 2>&1; then
		az group create  --location $LOCATION --resource-group $RESOURCEGROUP
	fi
}

function create_storage_account() {
	echo "Running ${FUNCNAME[0]}"

	#Check to make sure that the storage account name is unique
	if az storage account show --resource-group $RESOURCEGROUP --name $STORAGEACCOUNT >/dev/null 2>&1; then
		echo "Error: Storage account $STORAGEACCOUNT already exists"
		exit 1
	fi

	#Create the storage account, export a string, create fileshare, Azure-secret. 
	az storage account create --resource-group $RESOURCEGROUP --name $STORAGEACCOUNT --location $LOCATION
	export AZURE_STORAGE_CONNECTION_STRING=$(az storage account show-connection-string -n $STORAGEACCOUNT -g $RESOURCEGROUP	-o tsv)
	## Create sharename -  putting everything in debug folder. 
	az storage share create -n $SHARENAME --connection-string $AZURE_STORAGE_CONNECTION_STRING
	STORAGE_KEY=$(az storage account keys list --resource-group $RESOURCEGROUP --account-name $STORAGEACCOUNT --query "[0].value" -o tsv)
	
	kubectl create secret generic $SECRETNAME --from-literal=azurestorageaccountname=$STORAGEACCOUNT --from-literal=azurestorageaccountkey=$STORAGE_KEY
}


function test_storage_account_viability() {
	echo "Running ${FUNCNAME[0]}"
	#Test the viability of the storage account
if [[ -n $STORAGE_KEY ]]; then
	echo "Storage account created successfully"
  kubectl get secret | grep $SECRETNAME
	else
	echo "Error creating storage account"
fi
}

function storage_account() {
echo "Running ${FUNCNAME[0]}"
	create_resource_group $RESOURCEGROUP;
	create_storage_account $STORAGEACCOUNT;
	test_storage_account_viability
}


function daemon_set() {
	echo "Running ${FUNCNAME[0]}"
	# Choose which script to download/use/collect data.
	# pcap, cifs, podcpu
	#2023.07.17 The daemonset below is hardcoded for pcap... need to figure out the other coolness.
	#export NAME=pcap
	#Create a file called debug-daemonset.yaml with the following contents:
	#envsubst < kubectl apply -f - <<EOF


cat <<EOF > $RESOURCEGROUP/debug-pcap.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  #name: \${NAME}
  name: pcap
  namespace: default
spec:
  selector:
    matchLabels:
      #app: \${NAME}
      app: pcap
  template:
    metadata:
      labels:
        app: pcap
        #app: \${NAME}
    spec:
      hostPID: true
      securityContext:
        fsGroupChangePolicy: OnRootMismatch
      containers:
      - env:
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        #name:  \${NAME} 
        name: pcap
        command:
        - nsenter
        - --target
        - "1"
        - --net
        - --
        - bash
        - -xc
        - |
          PIDFILE="/var/run/pcap.pid"
          STARTTIME=\\\$(date -u +%Y%m%dT%H%M%S)
          if ! command -v tcpdump &> /dev/null
            then
            if command -v apt-get &> /dev/null; then
              DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y tcpdump
            elif command -v tdnf &> /dev/null; then
              tdnf install -y tcpdump util-linux
            else
              echo "No known package manager found is this a Windows node?"
              exit 44
            fi
          fi
          mkdir -p /debug/\\\$HOSTNAME
          echo "HOSTNAME:\\\$HOSTNAME"
          #sudo bash -c "nohup tcpdump -i any -s 100 -C 1000 -w /debug/\\\$HOSTNAME/\\\$STARTTIME.pcap"
          tcpdump -i any -s 100 -C 1000 -w "/debug/\\\$HOSTNAME/\\\$STARTTIME.pcap" &
          echo \\\$! > \\\$PIDFILE
          wait
          rm \\\$PIDFILE
          echo "sleeping forever"
          sleep infinity                  
        #image: ubuntu:latest
        #image: alpine:latest
        image: mcr.microsoft.com/dotnet/runtime-deps:6.0
        resources:
          requests:
            cpu: 50m
            memory: 50M
        securityContext:
          privileged: true
          capabilities:
            add:
            #- SYS_ADMIN
            #- SYS_PTRACE
            - NET_ADMIN
        volumeMounts:
        - name: azure 
          mountPath: /debug
      volumes:
      - name: azure
        persistentVolumeClaim:
          claimName: debug-share 
EOF

#envsubst < $RESOURCEGROUP/debug-template.yaml >> "${RESOURCEGROUP}/debug-${NAME}.yaml"
}

function create_pv_pvc(){
	echo "Running ${FUNCNAME[0]}"
cat << EOF > $RESOURCEGROUP/debugpvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: debug-share
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: azurefile-csi
  volumeName: debug-share-pv
  resources:
    requests:
      storage: 10Gi
EOF


cat << EOF > $RESOURCEGROUP/debugpv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: file.csi.azure.com
  name: debug-share-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azurefile-csi
  csi:
    driver: file.csi.azure.com
    readOnly: false
    #Create a unique volumehandle
    #volumeHandle: 1228487f-8a3a-90e0-c181-ubuntub2d8dc
    volumeHandle: $STORAGEACCOUNT
    volumeAttributes:
      resourceGroup: $RESOURCEGROUP
      shareName: $SHARENAME
    nodeStageSecretRef:
      name: $SECRETNAME
      namespace: default
  mountOptions:
    - dir_mode=0777
    - file_mode=0777
    - uid=0
    - gid=0
    - mfsymlinks
    - cache=strict
    - nosharesock
    - nobrl
EOF

}

function check_work(){
echo "Running ${FUNCNAME[0]}"
#Wait for the daemonset to be running
kubectl wait --for=condition=ready pod -l app=debug-${NAME}

#Verify that the storage account is mounted on all nodes
kubectl exec -it $(kubectl get pod -l app=debug-${NAME} -o jsonpath="{.items[0].metadata.name}") -- df -h

#Verify that the daemonset is capturing log data
kubectl logs -l app=debug-${NAME}

#This script will create a storage account in Azure called my-storage-account in the resource group my-resource-group. It will then create a daemonset called debug-daemonset that will run on all nodes of the AKS cluster. The daemonset will capture additional log data and write the data captured to /debug/logs/.

#Once the script has finished running, you can verify that the storage account is mounted on all nodes and that the daemonset is capturing log data by running the commands shown in the script.
}

function apply_config(){
kubectl apply -f $RESOURCEGROUP/debugpv.yaml
kubectl apply -f $RESOURCEGROUP/debugpvc.yaml
echo "Edit the debug-pcap file to remove the extra '\\' "
echo "Run the following command to apply the daemonset"
echo "kubectl apply -f ${RESOURCEGROUP}/debug-pcap.yaml"
#kubectl apply -f "${RESOURCEGROUP}/debug-${NAME}.yaml"

}


function github_pull(){
	echo "Running ${FUNCNAME[0]}"
	#mountSA locally pull scripts from github
	# Create a directory for the scripts
	mkdir /debug/scripts

	# Copy the scripts to the directory
	cp /path/to/scripts/* /debug/scripts

	# Set the permissions on the scripts
	chmod +x /debug/scripts/*

	# Create a directory for the logs
	mkdir /debug/logs/

	# Set the permissions on the logs directory
	chmod +777 /debug/logs
}


storage_account
create_pv_pvc
daemon_set
#check_work
apply_config

