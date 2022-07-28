
# Purpose of this fork was to tweak the original repository scripts to create a single node HCI cluster for testing purposes only

## What do the script/scripts do?

The templates / scripts are executed in a series of 3 steps. At the end of step 3 we get a Virtual Single node HCI cluster which is registed to Azure. Additionaly we get control plane and workload AKS clusters created on the HCI cluster, and registered as Kubernetes Azure Arc Clusters.

## Overview of steps

![Overview of Steps](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/diagrams/steps-overview.png)


Step 1 creates the Azure resources including the Azure VM with Windows Server 2019, Hyper-V, and DHCP server.  Step 2 creates a nested Hyper-V VM with HCI OS, Hyper-V, and sets up the properties, disks and networking needed for Step 3. Step 3 does the creation and registration of the Azure Stack HCI cluster, and AKS clusters (control plane and workload clusters) on top of the Azure Stack HCI cluster.

## Step Details (WIP)

* Go to the Root of this repo, click on deploy to Azure, add value of required parameters, and start the deployment.    This will create an Azure VM will all required windows features enabled and prequisites created to setup nested HCI VM. This step will take over 30 minutes
* Once the VM is created, RDP into the VM, and execute the powershell script [New-AzSHCISandbox.ps1](./Sandbox/New-AzSHCISandbox.ps1) using the desktop shortcut. This script creates the required network switches, volumes, and creates the nested node with HCI OS, and windows features like HyperV enabled. This step will take around 20 minutes to complete.
  * You may choose to modify some configuration values prior to executing this script. This script and its configuration file AzSHCISandbox-Config.psd1 are located at the path **C:\AzHCI_Sandbox\AzSHCISandbox-main** . Some of these configurations include:
    * NestedVMMemoryinGB: This is the RAM that will be allocated to the HCI cluster node. The minimum recommended value for this is 64GB. By default this value is set to 80GB
    * SDNDomainFQDN: This is the domain suffix which will get associated with the HCI cluster node. By default this is set to "contoso.com"
* Next we need to get a powershell session into the nested VM, and create a copy of the [config.txt](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/config.txt), [progress.log](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/progress.log) and [OneNode.ps1](./Sandbox/SingleNodeHCIClusterCreationAndRegistration/OneNode.ps1) files in the nested VM. You will need to have a look at the configurations in the config.txt file and modify as appropriate. Overview of configuration values can be found [here](https://github.com/microsoft/onenode-edge-poc/blob/Adding-Domain-Version/OneNode-NoDomain-Readme/OneNode-NoDomain.md#step-2-set-up-the-deployment-tool). Some key configuration values which you should consider modifying are : 
  * 
  * 

After required modifications have been made to config.txt file, execute the following command

    ```powershell
    & .\OneNode.ps1
    ```
    You will need to login in to your Azure Subscript once, after which the service principal is appended to the config.txt and used from there in the subsequent steps.

### Get Started with Step 1: Deploy to Azure ##

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FmaniSbindra%2FAzStackHCISandbox%2Fmain%2Fjson%2Fazuredeploy.json)

