
# Purpose of this fork was to tweak the original repository scripts to create a single node HCI cluster for testing purposes only

## Steps to Provision single node HCI nested VM (on Azure VM with nested virtualization), registering the HCI Cluster with Azure and installing AKS on the single node HCI cluster

* Go to the Root of this repo, click on deploy to Azure, add value of required parameters, and start the deployment.    This will create an Azure VM will all required windows features enabled and prequisites created to setup nested HCI VM. This step will take over 30 minutes
* Once the VM is created, RDP into the VM, and execute the powershell script [New-AzSHCISandbox.ps1](../../Sandbox/New-AzSHCISandbox.ps1) using the desktop shortcut. This script creates the required network switches, volumes, and creates the nested node with HCI OS, and windows features like HyperV enabled. This step will take around 20 minutes to complete.
* Next we need to get a powershell session into the nested VM, and create a copy of the [config.txt](../../Sandbox/SingleNodeHCIClusterCreationAndRegistration/config.txt), [progress.log](../../Sandbox/SingleNodeHCIClusterCreationAndRegistration/progress.log) and [OneNode.ps1](../../Sandbox/SingleNodeHCIClusterCreationAndRegistration/OneNode.ps1) files in the nested VM. After this modify required values in the config.txt file, and then execute 

```powershell
& .\OneNode.ps1
```
   You will need to login in to your Azure Subscript once, after which the service principal is appended to the config.txt and used from there in the subsequent steps.

## Deploy to Azure ##

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FmaniSbindra%2FAzStackHCISandbox%2Fmain%2Fjson%2Fazuredeploy.json)

