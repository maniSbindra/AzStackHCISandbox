
# Purpose of this fork was to tweak the original repository scripts to create a single node HCI cluster for testing purposes only

## Steps to Provision single node HCI nested VM (on Azure VM with nested virtualization), registering the HCI Cluster with Azure and installing AKS on the single node HCI cluster

* Go to the Root of this repo, click on deploy to Azure, add value of required parameters, and start the deployment. Alternately you can also deploy using powershell or az cli if you prefer. This will create an Azure VM will all required windows features enabled and prequisites created to setup nested HCI VM. This step will take over 30 minutes
* Once the VM is created, RDP into the VM, and execute the powershell script [New-AzSHCISandbox.ps1](./Sandbox/New-AzSHCISandbox.ps1) using the desktop shortcut. This script creates the required network switches, volumes, and creates the nested node with HCI OS, and windows features like HyperV enabled. This step will take around 20 minutes to complete.
* Next we need to get a powershell session into the nested VM, and create a copy of the [config.txt](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/config.txt) and [OneNode.ps1](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/OneNode.ps1) files in the nested VM. After this modify the subscription ID in the config.txt (and any other variable values you may wish to change). After this execute the 7 steps in the [OneNode.ps1](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/OneNode.ps1) file serially. In steps 6 and 7, you will be asked to login to your Azure account. After step 6, the HCI Cluster is registered in Azure, and after step 7, AKS gets installed on the single node HCI cluster.

## Deploy to Azure ##

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FmaniSbindra%2FAzStackHCISandbox%2Fmain%2Fjson%2Fazuredeploy.json)

