[CmdletBinding()] param (
    [ValidateSet("0.0 Learn More","1.0 Prepare Powershell","1.1 Install Azure Modules", "1.2 Prepare Host OS", "2.0 Create HCI Cluster", "2.1 Register HCI Cluster", "3.0 Install AKS on HCI")] 
    [String]$Step='Step-0-LearnMore',
    [Parameter()]
    [String]$ConfigFile='./config.txt'
)
# Read in required Globals from config.txt file
try {
    $config = ConvertFrom-StringData (Get-Content -Raw $ConfigFile)
    foreach($i in $config.Keys) {New-Variable -Name $i -Value ($config.$i) -Force}
}
catch {
    Write-Warning "Could not find or open $ConfigFile"
    Write-Warning "Please verify the file exists in the location specified"
    exit
}


# Generate some derived values. You can edit these if you'd like to use other names.

$ClusterName = "cl-$HciNodeName"
$AzResourceGroup = "rg-$HciNodeName"
$CloudAgentName = "ca-$HciNodeName"
$CloudAgentIp = $AksCloudIpCidr.Substring(0,($AksCloudIpCidr.IndexOf('/')))


function Show-OneNodeHelp { 

    Write-Host "TODO: Add information, URL to repo, etc."   
}

function Install-RequiredProviders {

    Install-PackageProvider -Name NuGet -Force 
    Install-Module -Name PowershellGet -Force -Confirm:$false -SkipPublisherCheck
    Write-Host "Press any key to close this console before proceeding with the next step"
    [console]::ReadKey($true)
    Stop-Process -Name conhost -Force -Confirm:$false
}

function Install-RequiredModules {

    # Get the modified Az.StackHci Module that will enable one-node registration
    Write-Verbose "Fetch the modified Az.StackHCI module needed for workgroup cluster registration"
    Remove-Item 'C:\Program Files\WindowsPowerShell\Modules\Az.StackHCI' -Recurse -Force -ErrorAction SilentlyContinue
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    # $hcicustommoduleuri="https://github.com/mgodfre3/Single-Node-POC/blob/main/Single-NodeHC-NoDomain/CustomModules.zip?raw=true"
    $hcicustommoduleuri="https://github.com/mgodfre3/Single-Node-POC/blob/8e034f345a47a6608294a63b0e50e1650ac6cf62/Single-NodeHC-NoDomain/CustomModules.zip?raw=true"
    New-Item -Path C:\ -Name Temp -ItemType Directory
    Invoke-WebRequest -Uri $hcicustommoduleuri -OutFile 'C:\Temp\Az.StackHCI-Custom.zip'
    Expand-Archive 'C:\Temp\AZ.StackHCI-Custom.zip' -DestinationPath 'C:\Temp' -Force
    Copy-Item -Path 'C:\Temp\CustomModules\Az.StackHCI' -Destination 'C:\Program Files\WindowsPowerShell\Modules' -Recurse
    
    # Get the modules that are needed for AksHci
    Install-Module -Name AksHci -Repository PSGallery

    # Authorize this system to run commands against Azure
    Connect-AzAccount -Subscription $AzSubscription -UseDeviceAuthentication

    # Register resource providers required by Azure Stack HCI
    Register-AzResourceProvider -ProviderNamespace Microsoft.Kubernetes
    Register-AzResourceProvider -ProviderNamespace Microsoft.KubernetesConfiguration

    <#Fetch the az cli. Might be required for other workloads.

    Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
    Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
    #>

}

function Install-HybridPrereqs {

    Rename-Computer -NewName $HciNodeName

    # Build a list of required features that need to be installed and install them
    $WinFeatures = "BitLocker", "Data-Center-Bridging", "Failover-Clustering", "FS-FileServer", "FS-Data-Deduplication", "Hyper-V", `
            "Hyper-V-PowerShell", "RSAT-AD-Powershell", "RSAT-Clustering-PowerShell", "NetworkATC", "Storage-Replica"

    Install-WindowsFeature -Name $WinFeatures -IncludeAllSubFeature -IncludeManagementTools

    # Clean up any previous attempts
    Clear-OneNodeConfig

    # We'll need to reboot here no matter what
    Write-Host "Press any key to reboot..."
    [console]::ReadKey($true)| Out-Null

    Restart-Computer -Force
}

function Deploy-OneNodeCluster {

    # Fetch the NICs that are up
    $adapter = (Get-NetAdapter -Physical | Where-Object {$_.Status -eq "Up"})

    # Create a VM Switch on the first NIC only (simplicty)
    Write-Verbose "Creating External VMSwitch"
    New-VMSwitch -Name "HCI-Uplink" -EnableEmbeddedTeaming $true -AllowManagementOS $true -MinimumBandwidthMode Weight -NetAdapterName $adapter[0].Name

    # Grab the IP address from the new vNIC
    $MgmtIP = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "vEthernet (HCI-Uplink)"

    # Write out the hosts entries for the node and cluster
    $hostRecord = ($MgmtIP.IPAddress + " $HciNodeName")
    Out-File "C:\Windows\System32\drivers\etc\hosts" -Encoding utf8 -Append -InputObject $hostRecord
    Out-File "C:\Windows\System32\drivers\etc\hosts" -Encoding utf8 -Append -InputObject "$ClusterIP $ClusterName"
    Out-File "C:\Windows\System32\drivers\etc\hosts" -Encoding utf8 -Append -InputObject "$CloudAgentIp $CloudAgentName"

    # Create the cluster
    Write-Verbose "Creating the Cluster"
    New-Cluster -Name $ClusterName -Node $HciNodeName -StaticAddress $ClusterIP -AdministrativeAccessPoint DNS -NoStorage
    
    # Enable S2D on the new cluster and create a volume
    Write-Verbose "Enabling Cluster Storage Spaces Direct"
    Enable-ClusterS2D -PoolFriendlyName "AsHciPool" -Confirm:$false
    Set-StoragePool -FriendlyName AsHciPool -FaultDomainAwarenessDefault 'PhysicalDisk'
    Write-Verbose "Creating Cluster Shared Volume"
    New-Volume -StoragePoolFriendlyName "AsHciPool" -FriendlyName "Volume01" -FileSystem CSVFS_ReFS -ResiliencySettingName Simple -UseMaximumSize
}

function Register-OneNodeCluster {

    # Clean upDownload the modified Az.StackHCI module
    Import-Module Az.StackHCI
    Register-AzStackHCI -SubscriptionId $AzSubscription -Region $AzRegion -ResourceName $ClusterName -ResourceGroupName $AzResourceGroup -UseDeviceAuthentication
}

function Deploy-AksHciOneNode {

    Initialize-AksHciNode
    Import-Module Moc

    $DnsServer = (Get-DnsClientServerAddress -InterfaceAlias "vEthernet (HCI-Uplink)" -AddressFamily IPv4).ServerAddresses[0]
    # Write-Verbose "DNS Server : $DnsServer"
    $DefaultGw = (Get-NetRoute "0.0.0.0/0").NextHop
    $DefaultGw = $DefaultGw[0]

    
    
    Write-Verbose "Setting AKS VNet" 
    
    $Vnet = New-AksHciNetworkSetting -name myvnet -vSwitchName "HCI-Uplink" -k8sNodeIpPoolStart $AksNodeIpPoolStart -k8sNodeIpPoolEnd $AksNodeIpPoolEnd `
        -vipPoolStart $AksVipPoolStart -vipPoolEnd $AksVipPoolEnd -ipAddressPrefix $CidrSubnet -gateway $DefaultGw -dnsServers $dnsServer
    
    Out-File "C:\Windows\System32\drivers\etc\hosts" -Encoding utf8 -Append -InputObject "$CloudAgentIp $CloudAgentName"

    Set-AksHciConfig -imageDir C:\ClusterStorage\Volume01\Images -workingDir C:\ClusterStorage\Volume01\ImageStore -clusterRoleName $CloudAgentName `
        -cloudConfigLocation C:\ClusterStorage\Volume01\Config -vnet $Vnet -cloudservicecidr $AksCloudIpCidr
    
    Write-Verbose "Re-Setting MOC Config for CloudFQDN"
    Set-MocConfigValue -Name "cloudFqdn" -Value $CloudAgentIp

    Write-Verbose -Message "Setting AKS Registation in Azure"
    Set-AksHciRegistration -subscriptionId $AzSubscription -resourceGroupName $AzResourceGroup -UseDeviceAuthentication
    
    Write-Verbose -Message "Installing AKS Now, this will take a bit of time"
    Install-AksHci
}

function Clear-OneNodeConfig {

        # Clean up VMswitch and Cluster if they exist
        $ErrorActionPreference = 'SilentlyContinue'
        Get-Cluster | Remove-Cluster -Confirm:$false -Force -ErrorAction SilentlyContinue
        Get-VMSwitch | Remove-VMSwitch -Confirm:$false -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = 'Continue'
    
        # Clear out storage devices
        Update-StorageProviderCache
        Get-StoragePool | Where-Object IsPrimordial -eq $false | Set-StoragePool -IsReadOnly:$false -ErrorAction SilentlyContinue
        Get-StoragePool | Where-Object IsPrimordial -eq $false | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
        Get-StoragePool | Where-Object IsPrimordial -eq $false | Remove-StoragePool -Confirm:$false -ErrorAction SilentlyContinue
        Get-PhysicalDisk | Reset-PhysicalDisk -ErrorAction SilentlyContinue
        Get-Disk | Where-Object Number -ne $null | Where-Object IsBoot -ne $true | Where-Object IsSystem -ne $true | Where-Object PartitionStyle -ne RAW | ForEach-Object {
            $_ | Set-Disk -isoffline:$false
            $_ | Set-Disk -isreadonly:$false
            $_ | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
            $_ | Set-Disk -isreadonly:$true
            $_ | Set-Disk -isoffline:$true
        }

    
}

$logFile = ('.\SingleNode-Transcipt-' + (Get-Date -f "yyyy-MM-dd") + '.log')
Start-Transcript -Path $logFile -Append

#Main

$Step = '3.0 Install AKS on HCI'

switch ($Step) {
    '0.0 Learn More'            { Show-OneNodeHelp }
    '1.0 Prepare Powershell'    { Install-RequiredProviders }
    '1.1 Install Azure Modules' { Install-RequiredModules }
    '1.2 Prepare Host OS'       { Install-HybridPrereqs }
    '2.0 Create HCI Cluster'    { Deploy-OneNodeCluster }
    '2.1 Register HCI Cluster'  { Register-OneNodeCluster }
    '3.0 Install AKS on HCI'    { Deploy-AksHciOneNode }
}

Stop-Transcript