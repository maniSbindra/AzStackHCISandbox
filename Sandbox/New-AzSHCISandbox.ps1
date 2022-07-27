<#
.SYNOPSIS 
    Deploys and configures a minimal Microsoft SDN infrastructure in a Hyper-V
    Nested Environment for training purposes. This deployment method is not
    supported for Production purposes.

.EXAMPLE
    .\New-AzSHCISandbox.ps1
    Reads in the configuration from AzSHCISandbox-Config.psd1 that contains a hash table 
    of settings data that will in same root as New-SDNSandbox.ps1
  
.EXAMPLE
    .\New-AzSHCISandbox.ps1 -Delete $true
     Removes the VMs and VHDs of the Azure Stack HCI Sandbox installation. (Note: Some files will
     remain after deletion.)

.NOTES
    Prerequisites:

    * All Hyper-V hosts must have Hyper-V enabled and the Virtual Switch 
    already created with the same name (if using Multiple Hosts). If you are
    using a single host, a Internal VM Switch will be created.

    * 250gb minimum of hard drive space if a single host installation. 150GB 
      minimum of drive space per Hyper-V host if using multiple hosts.

    * 64gb of memory if single host. 32GB of memory per host if using 2 hosts,
      and 16gb of memory if using 4 hosts.

    * If using multiple Hyper-V hosts for the lab, then you will need to either
    use a dumb hub to connect the hosts or a switch with all defined VLANs
    trunked (12 and 200).

    * If you wish the environment to have internet access, create a VMswitch on
      the FIRST host that maps to a NIC on a network that has internet access. 
      The network should use DHCP.

    * 2 VHDX (GEN2) files will need to be specified. 

        1. GUI.VHDX - Sysprepped Desktop Experience version of Windows Server 2019 
           Standard/Datacenter.

        2. AZHCI.VHDX - Generalized\ version of Azure Stack HCI. 
          

    * The AzSHCISandbox-Config.psd1 will need to be edited to include product keys for the
      installation media. If using VL Media, use KMS keys for the product key. Additionally,
      please ensure that the NAT settings are filled in to specify the switch allowing 
      internet access.
          
#>


[CmdletBinding(DefaultParameterSetName = "NoParameters")]

param(
    [Parameter(Mandatory = $true, ParameterSetName = "ConfigurationFile")]
    [String] $ConfigurationDataFile = '.\AzSHCISandbox-Config.psd1',
    [Parameter(Mandatory = $false, ParameterSetName = "Delete")]
    [Bool] $Delete = $false
) 

#region functions

function Get-HyperVHosts {

    param (

        [String[]]$MultipleHyperVHosts,
        [string]$HostVMPath
    )
    
    foreach ($HypervHost in $MultipleHyperVHosts) {

        # Check Network Connectivity
        Write-Verbose "Checking Network Connectivity for Host $HypervHost"
        $testconnection = Test-Connection -ComputerName $HypervHost -Quiet -Count 1
        if (!$testconnection) { Write-Error "Failed to ping $HypervHost"; break }
    
        # Check Hyper-V Host 
        $HypHost = Get-VMHost -ComputerName $HypervHost -ErrorAction Ignore
        if ($HypHost) { Write-Verbose "$HypervHost Hyper-V Connectivity verified" }
        if (!$HypHost) { Write-Error "Cannot connect to hypervisor on system $HypervHost"; break }
    
        # Check HostVMPath
        $DriveLetter = $HostVMPath.Split(':')
        $testpath = Test-Path (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1])) -ErrorAction Ignore
        if ($testpath) { Write-Verbose "$HypervHost's $HostVMPath path verified" }
        if (!$testpath) { Write-Error "Cannot connect to $HostVMPath on system $HypervHost"; break }

    }
    
} 
    
function Set-HyperVSettings {
    
    param (

        $MultipleHyperVHosts,
        $HostVMPath
    )
    
    foreach ($HypervHost in $MultipleHyperVHosts) {

        Write-Verbose "Configuring Hyper-V Settings on $HypervHost"

        $params = @{
        
            ComputerName              = $HypervHost
            # ComputerName              = "AzSHCIHost001"
            VirtualHardDiskPath       = $HostVMPath
            VirtualMachinePath        = $HostVMPath
            EnableEnhancedSessionMode = $true

        }

        Set-VMhost @params
    
    }
    
}
    
function Set-LocalHyperVSettings {

    Param (

        [string]$HostVMPath
    )
    
    Write-Verbose "Configuring Hyper-V Settings on localhost"

    $params = @{

        VirtualHardDiskPath       = $HostVMPath
        VirtualMachinePath        = $HostVMPath
        EnableEnhancedSessionMode = $true

    }

    Set-VMhost @params  
}
    
function New-InternalSwitch {
    
    Param (

        $pswitchname, 
        $SDNConfig
    )
    
    $pswitchname2 = "InternalSwitch"
    

    $querySwitch = Get-VMSwitch -Name $pswitchname2 -ErrorAction Ignore
    
    if (!$querySwitch) {
    
        New-VMSwitch -SwitchType Internal None -Name $pswitchname2 | Out-Null
    
        #Assign IP to Internal Switch
        $InternalAdapter = Get-Netadapter -Name "vEthernet ($pswitchname2)"
        $IP = $SDNConfig.PhysicalHostInternalIP
        $Prefix = "24"
        $Gateway = $SDNConfig.PhysicalHostInternalIP
        $DNS = $SDNConfig.PhysicalHostInternalIP
        
        $params = @{

            AddressFamily  = "IPv4"
            IPAddress      = $IP
            PrefixLength   = $Prefix
            DefaultGateway = $Gateway
            
        }
    
        $InternalAdapter | New-NetIPAddress @params | Out-Null
        $InternalAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null
    
    }
    
    Else { Write-Verbose "Internal Switch $pswitchname2 already exists. Not creating a new internal switch." }
    
}
    
function New-HostvNIC {
    
    param (

        $SDNConfig,
        $localCred
    )

    $ErrorActionPreference = "Stop"

    # $SBXIP = 250

    # foreach ($SDNSwitchHost in $SDNConfig.MultipleHyperVHostNames) {

    Write-Verbose "Creating vNIC on AzSHOST1"

    Invoke-Command -ComputerName "AzSHOST1" -ArgumentList $SDNConfig -ScriptBlock {

        $SDNConfig = $args[0]

        $vnicName = "vnicexternalaccess"
        $pswitchname2 = "InternalSwitch"

        $params = @{

            SwitchName = $pswitchname2
            Name       = $vnicName

        }
    
        Add-VMNetworkAdapter -ManagementOS @params | Out-Null
            

        Set-VMNetworkAdapterVlan -ManagementOS -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
  
        $IP = "192.168.1.250"
        $prefix = "24"
        $gateway = "192.168.1.1"
        $DNS = "192.168.1.1"

        $NetAdapter = Get-NetAdapter | Where-Object { $_.Name -match $vnicName }[0]

        $params = @{

            AddressFamily  = "IPv4"
            IPAddress      = $IP
            PrefixLength   = $Prefix
            DefaultGateway = $Gateway
            
        }

        $NetAdapter | New-NetIPAddress @params | Out-Null
        $NetAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null

    }

    $SBXIP--
    
    # }
    
}
    
function Test-VHDPath {

    Param (

        $guiVHDXPath,
        $azSHCIVHDXPath
    )

    $Result = Get-ChildItem -Path $guiVHDXPath -ErrorAction Ignore  
    if (!$result) { Write-Host "Path $guiVHDXPath was not found!" -ForegroundColor Red ; break }
    $Result = Get-ChildItem -Path $azSHCIVHDXPath -ErrorAction Ignore  
    if (!$result) { Write-Host "Path $azSHCIVHDXPath was not found!" -ForegroundColor Red ; break }

}
    
function Select-VMHostPlacement {
    
    Param($MultipleHyperVHosts, $AzSHOSTs)    
    
    $results = @()
    
    Write-Host "Note: if using a NAT switch for internet access, please choose the host that has the external NAT Switch for VM: AzSMGMT." `
        -ForegroundColor Yellow
    
    foreach ($AzSHOST in $AzSHOSTs) {
    
        Write-Host "`nOn which server should I put $AzSHOST ?" -ForegroundColor Green
    
        $i = 0
        foreach ($HypervHost in $MultipleHyperVHosts) {
    
            Write-Host "`n $i. Hyper-V Host: $HypervHost" -ForegroundColor Yellow
            $i++
        }
    
        $MenuOption = Read-Host "`nSelect the Hyper-V Host and then press Enter" 
    
        $results = $results + [pscustomobject]@{AzSHOST = $AzSHOST; VMHost = $MultipleHyperVHosts[$MenuOption] }
    
    }
    
    return $results
     
}
    
function Select-SingleHost {

    Param (

        $AzSHOSTs

    )

    $results = @()
    foreach ($AzSHOST in $AzSHOSTs) {

        $results = $results + [pscustomobject]@{AzSHOST = $AzSHOST; VMHost = $env:COMPUTERNAME }
    }

    Return $results

}
    
function Copy-VHDXtoHosts {

    Param (

        $MultipleHyperVHosts, 
        $guiVHDXPath, 
        $azSHCIVHDXPath, 
        $HostVMPath

    )
        
    foreach ($HypervHost in $MultipleHyperVHosts) { 

        $DriveLetter = $HostVMPath.Split(':')
        $path = (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]))
        Write-Verbose "Copying $guiVHDXPath to $path"
        Copy-Item -Path $guiVHDXPath -Destination "$path\GUI.vhdx" -Force | Out-Null
        Write-Verbose "Copying $azSHCIVHDXPath to $path"
        Copy-Item -Path $azSHCIVHDXPath -Destination "$path\AzSHCI.vhdx" -Force | Out-Null

    }
}
    
function Copy-VHDXtoHost {

    Param (

        $guiVHDXPath, 
        $HostVMPath, 
        $azSHCIVHDXPath

    )

    Write-Verbose "Copying $guiVHDXPath to $HostVMPath\GUI.VHDX"
    Copy-Item -Path $guiVHDXPath -Destination "$HostVMPath\GUI.VHDX" -Force | Out-Null
    Write-Verbose "Copying $azSHCIVHDXPath to $HostVMPath\AzSHCI.VHDX"
    Copy-Item -Path $azSHCIVHDXPath -Destination "$HostVMPath\AzSHCI.VHDX" -Force | Out-Null

      
    
}
    
function Get-guiVHDXPath {
    
    Param (

        $guiVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'GUI.vhdx'
    return $ParentVHDXPath

}
    
function Get-azSHCIVHDXPath {

    Param (

        $azSHCIVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'AzSHCI.vhdx'
    return $ParentVHDXPath

}
    
function Get-ConsoleVHDXPath {

    Param (

        $ConsoleVHDXPath, 
        $HostVMPath

    )

    $ParentVHDXPath = $HostVMPath + 'Console.vhdx'
    return $ParentVHDXPath

}

function New-NestedVM {

    Param (

        $AzSHOST, 
        $VMHost, 
        $HostVMPath, 
        $VMSwitch,
        $SDNConfig

    )
    
   
    $parentpath = "$HostVMPath\GUI.vhdx"
    $coreparentpath = "$HostVMPath\AzSHCI.vhdx"

    $vmMac = Invoke-Command -ComputerName $VMHost -ScriptBlock {    

        $VerbosePreference = "SilentlyContinue"

        Import-Module Hyper-V

        $VerbosePreference = "Continue"

        $AzSHOST = $using:AzSHOST
        $VMHost = $using:VMHost        
        $HostVMPath = $using:HostVMPath
        $VMSwitch = $using:VMSwitch
        $parentpath = $using:parentpath
        $coreparentpath = $using:coreparentpath
        $SDNConfig = $using:SDNConfig                         
        $S2DDiskSize = $SDNConfig.S2D_Disk_Size
        $NestedVMMemoryinGB = $SDNConfig.NestedVMMemoryinGB
        $AzSMGMTMemoryinGB = $SDNConfig.AzSMGMTMemoryinGB
    
        # Create Differencing Disk. Note: AzSMGMT is GUI

        if ($AzSHOST -eq "AzSMGMT") {

            $VHDX1 = New-VHD -ParentPath $parentpath -Path "$HostVMPath\$AzSHOST.vhdx" -Differencing 
            $VHDX2 = New-VHD -Path "$HostVMPath\$AzSHOST-Data.vhdx" -SizeBytes 268435456000 -Dynamic
            $NestedVMMemoryinGB = $AzSMGMTMemoryinGB
        }
    
        Else { 
           
            $VHDX1 = New-VHD -ParentPath $coreparentpath -Path "$HostVMPath\$AzSHOST.vhdx" -Differencing 
            $VHDX2 = New-VHD -Path "$HostVMPath\$AzSHOST-Data.vhdx" -SizeBytes 268435456000 -Dynamic
    
            # Create S2D Storage       

            New-VHD -Path "$HostVMPath\$AzSHOST-S2D_Disk1.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$AzSHOST-S2D_Disk2.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$AzSHOST-S2D_Disk3.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$AzSHOST-S2D_Disk4.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$AzSHOST-S2D_Disk5.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null
            New-VHD -Path "$HostVMPath\$AzSHOST-S2D_Disk6.vhdx" -SizeBytes $S2DDiskSize -Dynamic | Out-Null    
    
        }    
    
        #Create Nested VM

        $params = @{

            Name               = $AzSHOST
            MemoryStartupBytes = $NestedVMMemoryinGB 
            VHDPath            = $VHDX1.Path 
            SwitchName         = $VMSwitch
            Generation         = 2

        }

        New-VM @params | Out-Null
        Add-VMHardDiskDrive -VMName $AzSHOST -Path $VHDX2.Path
    
        if ($AzSHOST -ne "AzSMGMT") {

            Add-VMHardDiskDrive -Path "$HostVMPath\$AzSHOST-S2D_Disk1.vhdx" -VMName $AzSHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$AzSHOST-S2D_Disk2.vhdx" -VMName $AzSHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$AzSHOST-S2D_Disk3.vhdx" -VMName $AzSHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$AzSHOST-S2D_Disk4.vhdx" -VMName $AzSHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$AzSHOST-S2D_Disk5.vhdx" -VMName $AzSHOST | Out-Null
            Add-VMHardDiskDrive -Path "$HostVMPath\$AzSHOST-S2D_Disk6.vhdx" -VMName $AzSHOST | Out-Null

        }
    
        Set-VM -Name $AzSHOST -ProcessorCount 6 -AutomaticStartAction Start
        # Add-VMNetworkAdapter -VMName AzSHOST1 -Name intnic -SwitchName $switchName
        # Get-VMNetworkAdapter -VMName $AzSHOST | Rename-VMNetworkAdapter -NewName "SDN"
        # Get-VMNetworkAdapter -VMName $AzSHOST | Set-VMNetworkAdapter -DeviceNaming On -StaticMacAddress  ("{0:D12}" -f ( Get-Random -Minimum 0 -Maximum 99999 ))
        # Add-VMNetworkAdapter -VMName $AzSHOST -Name SDN2 -DeviceNaming On -SwitchName $VMSwitch
        Add-VMNetworkAdapter -VMName $AzSHOST -Name "intnetadp" -SwitchName $VMSwitch


        Add-VMNetworkAdapter -VMName $AzSHOST -Name SDN -SwitchName $VMSwitch
        Add-VMNetworkAdapter -VMName $AzSHOST -Name SDN2 -SwitchName $VMSwitch
        $vmMac = ((Get-VMNetworkAdapter -Name SDN -VMName $AzSHOST).MacAddress) -replace '..(?!$)', '$&-'
        Write-Verbose "Virtual Machine FABRIC NIC MAC is = $vmMac"

        if ($AzSHOST -ne "AzSMGMT") {

            Add-VMNetworkAdapter -VMName $AzSHOST -SwitchName $VMSwitch -DeviceNaming On -Name StorageA
            Add-VMNetworkAdapter -VMName $AzSHOST -SwitchName $VMSwitch -DeviceNaming On -Name StorageB


        }

        Get-VM $AzSHOST | Set-VMProcessor -ExposeVirtualizationExtensions $true
        Get-VM $AzSHOST | Set-VMMemory -DynamicMemoryEnabled $false
        Get-VM $AzSHOST | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

        

        # Set-VMNetworkAdapterVlan -VMName $AzSHOST -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
        # Set-VMNetworkAdapterVlan -VMName $AzSHOST -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200  

        if ($AzSHOST -ne "AzSMGMT") {

            Set-VMNetworkAdapterVlan -VMName $AzSHOST -VMNetworkAdapterName StorageA -Access -VlanId $SDNConfig.StorageAVLAN 
            Set-VMNetworkAdapterVlan -VMName $AzSHOST -VMNetworkAdapterName StorageB -Access -VlanId $SDNConfig.StorageBVLAN 


        }


        Enable-VMIntegrationService -VMName $AzSHOST -Name "Guest Service Interface"
        return $vmMac

    }
    
    
    return $vmMac          

}
    
function Add-Files {
    
    Param(
        $VMPlacement, 
        $HostVMPath, 
        $SDNConfig,
        $guiVHDXPath,
        $azSHCIVHDXPath,
        $vmMacs
    )
    
    $corevhdx = 'AzSHCI.vhdx'
    $guivhdx = 'GUI.vhdx'
    
    foreach ($AzSHOST in $VMPlacement) {
    
        # Get Drive Paths 

        $HypervHost = $AzSHOST.VMHost
        $DriveLetter = $HostVMPath.Split(':')
        $path = (("\\$HypervHost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $AzSHOST.AzSHOST + ".vhdx")       

        # Install Hyper-V Offline

        Write-Verbose "Performing offline installation of Hyper-V to path $path"
        Install-WindowsFeature -Vhd $path -Name Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Powershell -Confirm:$false | Out-Null
        Start-Sleep -Seconds 20       

    
        # Mount VHDX

        Write-Verbose "Mounting VHDX file at $path"
        [string]$MountedDrive = (Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition | Get-Volume).DriveLetter
        $MountedDrive = $MountedDrive.Replace(" ", "")

        # Get Assigned MAC Address so we know what NIC to assign a static IP to
        $vmMac = ($vmMacs | Where-Object { $_.Hostname -eq $AzSHost.AzSHOST }).vmMac

   
        # Inject Answer File

        Write-Verbose "Injecting answer file to $path"
    
        $AzSHOSTComputerName = $AzSHOST.AzSHOST
        $AzSHOSTIP = $SDNConfig.($AzSHOSTComputerName + "IP")
        $SDNAdminPassword = $SDNConfig.SDNAdminPassword
        $SDNDomainFQDN = $SDNConfig.SDNDomainFQDN
        $SDNLABDNS = $SDNConfig.SDNLABDNS    
        $SDNLabRoute = $SDNConfig.SDNLABRoute         
        $ProductKey = $SDNConfig.GUIProductKey

        # Only inject product key if host is AzSMGMT
        $azsmgmtProdKey = $null
        if ($AzSHOST.AzSHOST -eq "AzSMGMT") { $azsmgmtProdKey = "<ProductKey>$ProductKey</ProductKey>" }
            
 
        $UnattendXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
<settings pass="specialize">
<component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
<PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
<PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
</component>
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<ComputerName>$AzSHOSTComputerName</ComputerName>
$azsmgmtProdKey
</component>
<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<fDenyTSConnections>false</fDenyTSConnections>
</component>
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserLocale>en-us</UserLocale>
<UILanguage>en-us</UILanguage>
<SystemLocale>en-us</SystemLocale>
<InputLocale>en-us</InputLocale>
</component>
<component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<IEHardenAdmin>false</IEHardenAdmin>
<IEHardenUser>false</IEHardenUser>
</component>
<component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<Identifier>$vmMac</Identifier>
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$AzSHOSTIP</IpAddress>
</UnicastIpAddresses>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$SDNLabRoute</NextHopAddress>
<Prefix>0.0.0.0/0</Prefix>
<Metric>100</Metric>
</Route>
</Routes>
</Interface>
</Interfaces>
</component>
<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DNSSuffixSearchOrder>
<DomainName wcm:action="add" wcm:keyValue="1">$SDNDomainFQDN</DomainName>
</DNSSuffixSearchOrder>
<Interfaces>
<Interface wcm:action="add">
<DNSServerSearchOrder>
<IpAddress wcm:action="add" wcm:keyValue="1">$SDNLABDNS</IpAddress>
</DNSServerSearchOrder>
<Identifier>$vmMac</Identifier>
<DisableDynamicUpdate>false</DisableDynamicUpdate>
<DNSDomain>$SDNDomainFQDN</DNSDomain>
<EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
</Interface>
</Interfaces>
</component>
</settings>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<OOBE>
<HideEULAPage>true</HideEULAPage>
<SkipMachineOOBE>true</SkipMachineOOBE>
<SkipUserOOBE>true</SkipUserOOBE>
<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
 </OOBE>
<UserAccounts>
<AdministratorPassword>
<Value>$SDNAdminPassword</Value>
<PlainText>true</PlainText>
</AdministratorPassword>
</UserAccounts>
</component>
</settings>
<cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@
 
        Write-Verbose "Mounted Disk Volume is: $MountedDrive" 
        $PantherDir = Get-ChildItem -Path ($MountedDrive + ":\Windows")  -Filter "Panther"
        if (!$PantherDir) { New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null }
    
        Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force
    
        # Inject VMConfigs and create folder structure if host is AzSMGMT

        # if ($AzSHOST.AzSHOST -eq "AzSMGMT") {

        # Creating folder structure on AzSMGMT

        # Write-Verbose "Creating VMs\Base folder structure on AzSMGMT"
        # New-Item -Path ($MountedDrive + ":\VMs\Base") -ItemType Directory -Force | Out-Null

        Write-Verbose "Injecting VMConfigs to $path"
        Copy-Item -Path .\AzSHCISandbox-Config.psd1 -Destination ($MountedDrive + ":\") -Recurse -Force
        New-Item -Path ($MountedDrive + ":\") -Name VMConfigs -ItemType Directory -Force | Out-Null
        # Copy-Item -Path $guiVHDXPath -Destination ($MountedDrive + ":\VMs\Base\GUI.vhdx") -Force
        # Copy-Item -Path $azSHCIVHDXPath -Destination ($MountedDrive + ":\VMs\Base\AzSHCI.vhdx") -Force
        Copy-Item -Path .\Applications\SCRIPTS -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
        Copy-Item -Path .\Applications\SDNEXAMPLES -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force
        Copy-Item -Path '.\Applications\Windows Admin Center' -Destination ($MountedDrive + ":\VmConfigs") -Recurse -Force  

        # }       
    
        # Dismount VHDX

        Write-Verbose "Dismounting VHDX File at path $path"
        Dismount-VHD $path
                                       
    }    
}
    
function Start-AzSHOSTS {

    Param(

        $VMPlacement

    )
    
    foreach ($VMHost in $VMPlacement) {

        Write-Verbose "Starting VM: $VMHost"
        Start-VM -ComputerName $VMHost.VMhost -Name $VMHost.AzSHOST

    }    
} 
    
function New-DataDrive {

    param (

        $VMPlacement, 
        $SDNConfig,
        $localCred
        
    )

    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost  -ScriptBlock {

            $VerbosePreference = "Continue"
            Write-Verbose "Onlining, partitioning, and formatting Data Drive on $($Using:SDNVM.AzSHOST)"

            $localCred = new-object -typename System.Management.Automation.PSCredential -argumentlist "Administrator" `
                , (ConvertTo-SecureString $using:SDNConfig.SDNAdminPassword   -AsPlainText -Force)   

            Invoke-Command -VMName $using:SDNVM.AzSHOST -Credential $localCred -ScriptBlock {

                Set-Disk -Number 1 -IsOffline $false | Out-Null
                Initialize-Disk -Number 1 | Out-Null
                New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter | Out-Null
                Format-Volume -DriveLetter D | Out-Null

            }                      
        }
    }    
}
    
function Test-AzSHOSTVMConnection {

    param (

        $VMPlacement, 
        $localCred

    )

    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost  -ScriptBlock {
            
            $VerbosePreference = "Continue"    
            
            $localCred = $using:localCred   
            $testconnection = $null
    
            While (!$testconnection) {
    
                $testconnection = Invoke-Command -VMName $using:SDNVM.AzSHOST -ScriptBlock { Get-Process } -Credential $localCred -ErrorAction Ignore
    
            }
        
            Write-Verbose "Successfully contacted $($using:SDNVM.AzSHOST)"
                         
        }
    }    
}

function Start-PowerShellScriptsOnHosts {

    Param (

        $VMPlacement, 
        $ScriptPath, 
        $localCred

    ) 
    
    foreach ($SDNVM in $VMPlacement) {

        Invoke-Command -ComputerName $SDNVM.VMHost  -ScriptBlock {
            
            $VerbosePreference = "Continue"    
            Write-Verbose "Executing Script: $($using:ScriptPath) on host $($using:SDNVM.AzSHOST)"     
            Invoke-Command -VMName $using:SDNVM.AzSHOST -ArgumentList $using:Scriptpath -ScriptBlock { Invoke-Expression -Command $args[0] } -Credential $using:localCred 
            
        }
    }
}
    
function New-NATSwitch {
    
    Param (

        $VMPlacement,
        $SwitchName,
        $SDNConfig

    )
    
    $natSwitchTarget = $VMPlacement | Where-Object { $_.AzSHOST -eq "AzSMGMT" }
    
    Add-VMNetworkAdapter -VMName $natSwitchTarget.AzSHOST -ComputerName $natSwitchTarget.VMHost -DeviceNaming On 

    $params = @{

        VMName       = $natSwitchTarget.AzSHOST
        ComputerName = $natSwitchTarget.VMHost
    }

    Get-VMNetworkAdapter @params | Where-Object { $_.Name -match "Network" } | Connect-VMNetworkAdapter -SwitchName $SDNConfig.natHostVMSwitchName
    Get-VMNetworkAdapter @params | Where-Object { $_.Name -match "Network" } | Rename-VMNetworkAdapter -NewName "NAT"
    
    Get-VM @params | Get-VMNetworkAdapter -Name NAT | Set-VMNetworkAdapter -MacAddressSpoofing On
    
    <# Should not need this anymore

    if ($SDNConfig.natVLANID) {
    
        Get-VM @params | Get-VMNetworkAdapter -Name NAT | Set-VMNetworkAdapterVlan -Access -VlanId $natVLANID | Out-Null
    
    }

    #>
    
    #Create PROVIDER NIC in order for NAT to work from SLB/MUX and RAS Gateways

    Add-VMNetworkAdapter @params -Name PROVIDER -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name PROVIDER | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name PROVIDER | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.providerVLAN | Out-Null    
    
    #Create VLAN 200 NIC in order for NAT to work from L3 Connections

    Add-VMNetworkAdapter @params -Name VLAN200 -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name VLAN200 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name VLAN200 | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.vlan200VLAN | Out-Null    

    
    #Create Simulated Internet NIC in order for NAT to work from L3 Connections

    Add-VMNetworkAdapter @params -Name simInternet -DeviceNaming On -SwitchName $SwitchName
    Get-VM @params | Get-VMNetworkAdapter -Name simInternet | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VM @params | Get-VMNetworkAdapter -Name simInternet | Set-VMNetworkAdapterVlan -Access -VlanId $SDNConfig.simInternetVLAN | Out-Null

    
}  
    
function Resolve-Applications {

    Param (

        $SDNConfig
    )
    
    # Verify Product Keys

    Write-Verbose "Performing simple validation of Product Keys"
    $guiResult = $SDNConfig.GUIProductKey -match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
    $coreResult = $SDNConfig.COREProductKey -match '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$'
    
    if (!$guiResult) { Write-Error "Cannot validate or find the product key for the Windows Server Datacenter Desktop Experience." }
    

    # Verify Windows Admin Center
    $isWAC = Get-ChildItem -Path '.\Applications\Windows Admin Center' -Filter *.MSI
    if (!$isWAC) { Write-Error "Please check and ensure that you have correctly copied the Admin Center install file to \Applications\RSAT." }

    # Are we on Server Core?
    $regKey = "hklm:/software/microsoft/windows nt/currentversion"
    $Core = (Get-ItemProperty $regKey).InstallationType -eq "Server Core"
    If ($Core) {
    
        Write-Warning "You might not want to run the Azure Stack HCI OS Sandbox on Server Core, getting remote access to the AdminCenter VM may require extra configuration."
        Start-Sleep -Seconds 5

    }
    
    
}
        
function Get-PhysicalNICMTU {
    
    Param (
        
        $SDNConfig
    
    )
    
    foreach ($VMHost in $SDNConfig.MultipleHyperVHostNames) {
    
        Invoke-Command -ComputerName $VMHost  -ScriptBlock {
    
            $SDNConfig = $using:SDNConfig
    
            $VswitchNICs = (Get-VMSwitch -Name ($SDNConfig.MultipleHyperVHostExternalSwitchName)).NetAdapterInterfaceDescription
    
            if ($VswitchNICs) {
                foreach ($VswitchNIC in $VswitchNICs) {
    
                    $MTUSetting = (Get-NetAdapterAdvancedProperty -InterfaceDescription $VswitchNIC -RegistryKeyword '*JumboPacket').RegistryValue

                    if ($MTUSetting -ne $SDNConfig.SDNLABMTU) {
    
                        Write-Error "There is a mismatch in the MTU value for the external switch and the value in the AzSHCISandbox-Config.psd1 data file."  
    
                    }
    
                }
    
            }
    
            else {
    
                Write-Error "The external switch was not found on $Env:COMPUTERNAME"
    
            }
    
        }    
    
    }
    
}

function Set-SDNserver {

    Param (

        $VMPlacement, 
        $SDNConfig, 
        $localCred 

    )


    # Set base number for Storage IPs
    $int = 9


    foreach ($SDNVM in $VMPlacement) {

    
        # Increment Storage IPs

        $int++


        Invoke-Command -ComputerName $SDNVM.VMHost -ScriptBlock {

            Invoke-Command -VMName $using:SDNVM.AzSHOST -ArgumentList $using:SDNConfig, $using:localCred, $using:int  -ScriptBlock {

                $SDNConfig = $args[0]
                $localCred = $args[1]
                $int = $args[2]
                $VerbosePreference = "Continue"


                # Create IP Address of Storage Adapters

                $storageAIP = $sdnconfig.storageAsubnet.Replace("0/24", $int)
                $storageBIP = $sdnconfig.storageBsubnet.Replace("0/24", $int)

                # Set Dns suffix
                # $dnsSuffix = $sdnconfig.SDNDomainFQDN
                # Write-Verbose "Setting DNS suffix in $env:COMPUTERNAME"
                # Set-ItemProperty “HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\” –Name Domain –Value $dnsSuffix | Out-Null
                # Write-Verbose "DNS suffix set in $env:COMPUTERNAME" 
                # Write-Verbose "Setting DNS suffix in $env:COMPUTERNAME"
                # $VerbosePreference = "SilentlyContinue"
                # Set-ItemProperty “HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\” –Name Domain –Value $dnsSuffix
                # $VerbosePreference = "Continue"
                # Write-Verbose "DNS suffix set in $env:COMPUTERNAME"
                

                # Set Name and IP Addresses on Storage Interfaces
                $storageNICs = Get-NetAdapterAdvancedProperty | Where-Object { $_.DisplayValue -match "Storage" }

                foreach ($storageNIC in $storageNICs) {

                    Rename-NetAdapter -Name $storageNIC.Name -NewName  $storageNIC.DisplayValue        

                }

                $storageNICs = Get-Netadapter | Where-Object { $_.Name -match "Storage" }

                foreach ($storageNIC in $storageNICs) {

                    If ($storageNIC.Name -eq 'StorageA') { New-NetIPAddress -InterfaceAlias $storageNIC.Name -IPAddress $storageAIP -PrefixLength 24 | Out-Null }  
                    If ($storageNIC.Name -eq 'StorageB') { New-NetIPAddress -InterfaceAlias $storageNIC.Name -IPAddress $storageBIP -PrefixLength 24 | Out-Null }  

                }




                # Enable WinRM

                Write-Verbose "Enabling Windows Remoting in $env:COMPUTERNAME"
                $VerbosePreference = "SilentlyContinue" 
                Set-Item WSMan:\localhost\Client\TrustedHosts *  -Confirm:$false -Force
                Enable-PSRemoting | Out-Null
                $VerbosePreference = "Continue" 

                Start-Sleep -Seconds 60

                if ($env:COMPUTERNAME -ne "AzSMGMT") {

                    Write-Verbose "Installing and Configuring Failover Clustering on $env:COMPUTERNAME"
                    $VerbosePreference = "SilentlyContinue"
                    Install-WindowsFeature -Name Failover-Clustering -IncludeAllSubFeature -IncludeManagementTools -ComputerName $env:COMPUTERNAME -Credential $localCred | Out-Null 


                    


                }

                # Enable CredSSP and MTU Settings

                Invoke-Command -ComputerName localhost -Credential $localCred -ScriptBlock {

                    $fqdn = $Using:SDNConfig.SDNDomainFQDN

                    Write-Verbose "Enabling CredSSP on $env:COMPUTERNAME"
                    Enable-WSManCredSSP -Role Server -Force
                    Enable-WSManCredSSP -Role Client -DelegateComputer localhost -Force
                    Enable-WSManCredSSP -Role Client -DelegateComputer $env:COMPUTERNAME -Force
                    Enable-WSManCredSSP -Role Client -DelegateComputer $fqdn -Force
                    Enable-WSManCredSSP -Role Client -DelegateComputer "*.$fqdn" -Force
                    New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation `
                        -Name AllowFreshCredentialsWhenNTLMOnly -Force
                    New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly `
                        -Name 1 -Value * -PropertyType String -Force 
                } -InDisconnectedSession | Out-Null
 
            } -Credential $using:localCred

        }

    }

}


function Delete-AzSHCISandbox {

    param (

        $VMPlacement,
        $SDNConfig,
        $SingleHostDelete

    )

    $VerbosePreference = "Continue"

    Write-Verbose "Deleting Azure Stack HCI Sandbox"

    foreach ($vm in $VMPlacement) {

        $AzSHOSTName = $vm.vmHost
        $VMName = $vm.AzSHOST

        Invoke-Command -ComputerName $AzSHOSTName -ArgumentList $VMName -ScriptBlock {

            $VerbosePreference = "SilentlyContinue"

            Import-Module Hyper-V

            $VerbosePreference = "Continue"
            $vmname = $args[0]

            # Delete SBXAccess vNIC (if present)
            $vNIC = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.Name -match "SBXAccess" }
            if ($vNIC) { $vNIC | Remove-VMNetworkAdapter -Confirm:$false }

            $sdnvm = Get-VM | Where-Object { $_.Name -eq $vmname }

            If (!$sdnvm) { Write-Verbose "Could not find $vmname to delete" }

            if ($sdnvm) {

                Write-Verbose "Shutting down VM: $sdnvm)"

                Stop-VM -VM $sdnvm -TurnOff -Force -Confirm:$false 
                $VHDs = $sdnvm | Select-Object VMId | Get-VHD
                Remove-VM -VM $sdnvm -Force -Confirm:$false 

                foreach ($VHD in $VHDs) {

                    Write-Verbose "Removing $($VHD.Path)"
                    Remove-Item -Path $VHD.Path -Force -Confirm:$false

                }

            }


        }

    }

    If ($SingleHostDelete -eq $true) {
        
        $RemoveSwitch = Get-VMSwitch | Where-Object { $_.Name -match $SDNConfig.InternalSwitch }

        If ($RemoveSwitch) {

            Write-Verbose "Removing Internal Switch: $($SDNConfig.InternalSwitch)"
            $RemoveSwitch | Remove-VMSwitch -Force -Confirm:$false

        }

    }

    Write-Verbose "Deleting RDP links"

    Remove-Item C:\Users\Public\Desktop\AdminCenter.lnk -Force -ErrorAction SilentlyContinue


    Write-Verbose "Deleting NetNAT"
    Get-NetNAT | Remove-NetNat -Confirm:$false

    Write-Verbose "Deleting Internal Switches"
    Get-VMSwitch | Where-Object { $_.SwitchType -eq "Internal" } | Remove-VMSwitch -Force -Confirm:$false


}


function test-internetConnect {

    $testIP = '1.1.1.1'
    $ErrorActionPreference = "Stop"  
    $intConnect = Test-Connection -ComputerName $testip -Quiet -Count 2

    if (!$intConnect) {

        Write-Error "Unable to connect to Internet. An Internet connection is required."

    }

}

function set-hostnat {

    param (

        $SDNConfig
    )

    $VerbosePreference = "Continue" 

    $switchExist = Get-NetAdapter | Where-Object { $_.Name -match $SDNConfig.natHostVMSwitchName }

    if (!$switchExist) {

        Write-Verbose "Creating Internal NAT Switch: $($SDNConfig.natHostVMSwitchName)"
        # Create Internal VM Switch for NAT
        New-VMSwitch -Name $SDNConfig.natHostVMSwitchName -SwitchType Internal | Out-Null

        Write-Verbose "Applying IP Address to NAT Switch: $($SDNConfig.natHostVMSwitchName)"
        # Apply IP Address to new Internal VM Switch
        $intIdx = (Get-NetAdapter | Where-Object { $_.Name -match $SDNConfig.natHostVMSwitchName }).ifIndex
        $natIP = $SDNConfig.natHostSubnet.Replace("0/24", "1")

        New-NetIPAddress -IPAddress $natIP -PrefixLength 24 -InterfaceIndex $intIdx | Out-Null

        # Create NetNAT

        Write-Verbose "Creating new NETNAT"
        New-NetNat -Name $SDNConfig.natHostVMSwitchName  -InternalIPInterfaceAddressPrefix $SDNConfig.natHostSubnet | Out-Null

    }

}

function Set-DNS-Suffix {

    param (

        $computerName,
        $dnsSuffix, 
        $localCred

    )
  

    Invoke-Command -ComputerName $computerName -ArgumentList $dnsSuffix -Credential $localCred -ScriptBlock {

        $dnsSuffix = $args[0]
        Write-Verbose "Setting DNS suffix"
        Set-ItemProperty “HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\” –Name Domain –Value $dnsSuffix | Out-Null
        Write-Verbose "DNS suffix set" 


    } 

}

#endregion
   
#region Main

    
$WarningPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop" 



#Get Start Time
$starttime = Get-Date
   
    
# Import Configuration Module

$SDNConfig = Import-PowerShellDataFile -Path $ConfigurationDataFile
Copy-Item $ConfigurationDataFile -Destination .\Applications\SCRIPTS -Force

Write-Verbose "SDNConfig is $SDNConfig"

# Set VM Host Memory
# $totalPhysicalMemory = (Get-CimInstance -ClassName 'Cim_PhysicalMemory' | Measure-Object -Property Capacity -Sum).Sum / 1GB
# $availablePhysicalMemory = (([math]::Round(((((Get-Counter -Counter '\Hyper-V Dynamic Memory Balancer(System Balancer)\Available Memory For Balancing' -ComputerName $env:COMPUTERNAME).CounterSamples.CookedValue) / 1024) - 18) / 2))) * 1073741824
# $SDNConfig.NestedVMMemoryinGB = $availablePhysicalMemory

# Set-Credentials
$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist "Administrator", (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)

$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\Administrator"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword  -AsPlainText -Force)

$NCAdminCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\NCAdmin"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword  -AsPlainText -Force)

$NCClientCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SDNConfig.SDNDomainFQDN.Split(".")[0]) + "\NCClient"), `
(ConvertTo-SecureString $SDNConfig.SDNAdminPassword  -AsPlainText -Force)

# Define SDN host Names. Please do not change names as these names are hardcoded in the setup.
# $AzSHOSTs = @("AzSMGMT", "AzSHOST1", "AzSHOST2")
$AzSHOSTs = @("AzSHOST1")


# Delete configuration if specified

if ($Delete) {

    if ($SDNConfig.MultipleHyperVHosts) {

        $params = @{

            MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
            AzSHOSTs            = $AzSHOSTs    

        }       

        $VMPlacement = Select-VMHostPlacement @params
        $SingleHostDelete = $false
    }     
    elseif (!$SDNConfig.MultipleHyperVHosts) { 
    
        Write-Verbose "This is a single host installation"
        $VMPlacement = Select-SingleHost -AzSHOSTs $AzSHOSTs
        $SingleHostDelete = $true

    }

    Delete-AzSHCISandbox -SDNConfig $SDNConfig -VMPlacement $VMPlacement -SingleHostDelete $SingleHostDelete

    Write-Verbose "Successfully Removed the Azure Stack HCI Sandbox"
    exit

}
    
# Set Variables from config file

$NestedVMMemoryinGB = $SDNConfig.NestedVMMemoryinGB
$guiVHDXPath = $SDNConfig.guiVHDXPath
$azSHCIVHDXPath = $SDNConfig.azSHCIVHDXPath
$HostVMPath = $SDNConfig.HostVMPath
$InternalSwitch = $SDNConfig.InternalSwitch
$natDNS = $SDNConfig.natDNS
$natSubnet = $SDNConfig.natSubnet
$natConfigure = $SDNConfig.natConfigure   


$VerbosePreference = "SilentlyContinue" 
Import-Module Hyper-V 
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"
    

# Enable PSRemoting

Write-Verbose "Enabling PS Remoting on client..."
$VerbosePreference = "SilentlyContinue"
Enable-PSRemoting
Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
$VerbosePreference = "Continue"

# Verify Applications

Resolve-Applications -SDNConfig $SDNConfig

# Verify Internet Connectivity
test-internetConnect
    
# if single host installation, set up installation parameters

if (!$SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "No Multiple Hyper-V Hosts defined. Using Single Hyper-V Host Installation"
    Write-Verbose "Testing VHDX Path"

    $params = @{

        guiVHDXPath    = $guiVHDXPath
        azSHCIVHDXPath = $azSHCIVHDXPath
    
    }

    Test-VHDPath @params

    Write-Verbose "Generating Single Host Placement"

    $VMPlacement = Select-SingleHost -AzSHOSTs $AzSHOSTs

    Write-Verbose "Creating Internal Switch"

    $params = @{

        pswitchname = $InternalSwitch
        SDNConfig   = $SDNConfig
    
    }

    
    # Creating Internal Switch

    $switchName = "newintswitch"
    New-VMSwitch -Name $switchName -SwitchType Internal
    New-NetNat –Name $switchName –InternalIPInterfaceAddressPrefix “192.168.0.0/24”
    $ifIndex = (Get-NetAdapter | ? { $_.name -like "*$switchName)" }).ifIndex
    New-NetIPAddress -IPAddress 192.168.0.1 -InterfaceIndex $ifIndex -PrefixLength 24

    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("168.63.129.16")

    # VNics connected to switch will be given IPs via DHCP
    Add-DhcpServerV4Scope -Name "DHCP-$switchName" -StartRange 192.168.0.50 -EndRange 192.168.0.100 -SubnetMask 255.255.255.0
    Set-DhcpServerV4OptionValue -Router 192.168.0.1 -DnsServer 168.63.129.16
    Restart-service dhcpserver

    
    Write-Verbose "Creating NAT Switch"

    # set-hostnat -SDNConfig $SDNConfig

    $VMSwitch = $InternalSwitch

    Write-Verbose "Getting local Parent VHDX Path"

    $params = @{

        guiVHDXPath = $guiVHDXPath
        HostVMPath  = $HostVMPath
    
    }


    $ParentVHDXPath = Get-guiVHDXPath @params

    Set-LocalHyperVSettings -HostVMPath $HostVMPath

    $params = @{

        azSHCIVHDXPath = $azSHCIVHDXPath
        HostVMPath     = $HostVMPath
    
    }

    $coreParentVHDXPath = Get-azSHCIVHDXPath @params


}
    
# if multiple host installation, set up installation parameters

if ($SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Multiple Hyper-V Hosts defined. Using Mutiple Hyper-V Host Installation"
    Get-PhysicalNICMTU -SDNConfig $SDNConfig

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        HostVMPath          = $HostVMPath
        
    }

    Get-HyperVHosts @params

    Write-Verbose "Testing VHDX Path"

    $params = @{

        guiVHDXPath    = $guiVHDXPath
        azSHCIVHDXPath = $azSHCIVHDXPath
    
    }


    Test-VHDPath @params

    Write-Verbose "Generating Multiple Host Placement"

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        AzSHOSTs            = $AzSHOSTs
    }

    $VMPlacement = Select-VMHostPlacement @params

    Write-Verbose "Getting local Parent VHDX Path"

    $params = @{

        guiVHDXPath = $guiVHDXPath
        HostVMPath  = $HostVMPath
    
    }

    $ParentVHDXPath = Get-guiVHDXPath @params

    $params = @{

        MultipleHyperVHosts = $MultipleHyperVHosts
        HostVMPath          = $HostVMPath
    
    }

    Set-HyperVSettings @params


    $params = @{

        azSHCIVHDXPath = $azSHCIVHDXPath
        HostVMPath     = $HostVMPath
    
    }


    $coreParentVHDXPath = Get-azSHCIVHDXPath @params


    $VMSwitch = $SDNConfig.MultipleHyperVHostExternalSwitchName

    # Write-Verbose "Creating vNIC on $env:COMPUTERNAME"
    # New-HostvNIC -SDNConfig $SDNConfig -localCred $localCred

}
    
    
# if multiple host installation, copy the parent VHDX file to the specified Parent VHDX Path

if ($SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Copying VHDX Files to Host"

    $params = @{

        MultipleHyperVHosts = $SDNConfig.MultipleHyperVHostNames
        azSHCIVHDXPath      = $azSHCIVHDXPath
        HostVMPath          = $HostVMPath
        guiVHDXPath         = $guiVHDXPath 

    }

    Copy-VHDXtoHosts @params
}
    
    
# if single host installation, copy the parent VHDX file to the specified Parent VHDX Path

if (!$SDNConfig.MultipleHyperVHosts) {

    Write-Verbose "Copying VHDX Files to Host"

    $params = @{

        azSHCIVHDXPath = $azSHCIVHDXPath
        HostVMPath     = $HostVMPath
        guiVHDXPath    = $guiVHDXPath 
    }

    Copy-VHDXtoHost @params
}
    
    
# Create Virtual Machines

$vmMacs = @()

# foreach ($VM in $VMPlacement) {
$VM = $VMPlacement[0]

Write-Verbose "Generating the VM: $VM" 

$params = @{

    VMHost     = $VM.VMHost
    AzSHOST    = $VM.AzSHOST
    HostVMPath = $HostVMPath
    VMSwitch   = $switchName
    SDNConfig  = $SDNConfig

}

$vmMac = New-NestedVM @params

Write-Verbose "Returned VMMac is $vmMac"

$vmMacs += [pscustomobject]@{

    Hostname = $VM.AzSHOST
    vmMAC    = $vmMac

}
        
#}
    
# Inject Answer Files and Binaries into Virtual Machines

$params = @{

    VMPlacement    = $VMPlacement
    HostVMPath     = $HostVMPath
    SDNConfig      = $SDNConfig
    guiVHDXPath    = $guiVHDXPath
    azSHCIVHDXPath = $azSHCIVHDXPath
    vmMacs         = $vmMacs

}

Add-Files @params
    
# Start Virtual Machines

Start-AzSHOSTS -VMPlacement $VMPlacement
    
# Wait for AzSHOSTs to come online

Write-Verbose "Waiting for VMs to provision and then come online"

$params = @{

    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Test-AzSHOSTVMConnection @params
    
# Online and Format Data Volumes on Virtual Machines

$params = @{

    VMPlacement = $VMPlacement
    SDNConfig   = $SDNConfig
    localcred   = $localCred

}

New-DataDrive @params
    
# Install SDN Host Software on NestedVMs

$params = @{

    SDNConfig   = $SDNConfig
    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Set-SDNserver @params
    
# Rename NICs from Ethernet to FABRIC

$params = @{

    scriptpath  = 'Get-Netadapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC'
    VMPlacement = $VMPlacement
    localcred   = $localCred

}

# Start-PowerShellScriptsOnHosts @params

$params.scriptpath = 'Get-Netadapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN2"}).Name) | Rename-NetAdapter -NewName FABRIC2'

# Start-PowerShellScriptsOnHosts @params
    
# Restart Machines

$params.scriptpath = "Restart-Computer -Force"
Start-PowerShellScriptsOnHosts @params
Start-Sleep -Seconds 30
    
# Wait for AzSHOSTs to come online

Write-Verbose "Waiting for VMs to restart..."

$params = @{

    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Test-AzSHOSTVMConnection @params
    
# This step has to be done as during the Hyper-V install as hosts reboot twice.

Write-Verbose "Ensuring that all VMs have been restarted after Hyper-V install.."
Test-AzSHOSTVMConnection @params


# Set DNS suffix for single node cluster
Write-Verbose "Setting DNS Suffix on Hosts"
$params = @{

    computerName = "AzSHOST1"
    dnsSuffix    = $SDNConfig.SDNDomainFQDN
    localcred    = $localCred

}

Set-DNS-Suffix @params

# $params.scriptpath = "Restart-Computer -Force"
# Start-PowerShellScriptsOnHosts @params

Start-Sleep -Seconds 30


Restart-VM -Name AzsHost1 -Force 

$params = @{

    VMPlacement = $VMPlacement
    localcred   = $localCred

}

Test-AzSHOSTVMConnection @params

   
# Wait for AzSHOSTs to come online

Write-Verbose "Waiting for VMs to restart..."


# Install Windows Admin Center
Write-Verbose "Installing Windows Admin Center on Host VM"
$arguments = "/qn /L*v C:\log.txt SME_PORT=443 SSL_CERTIFICATE_OPTION=generate "
Start-Process -FilePath "C:\AzHCI_Sandbox\AzSHCISandbox-main\Applications\Windows Admin Center\WindowsAdminCenter.msi" -ArgumentList $arguments  -PassThru| Wait-Process 

# Install Chocolatey and Microsoft Edge
$ErrorActionPreference = "Continue"
Write-Verbose "Installing Chocolatey on Host VM"
Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
Start-Sleep -Seconds 10

Write-Verbose "Installing Microsoft Edge on Host VM"
choco install microsoft-edge -y --force 
    

# Finally - Add RDP Link to Desktop

Remove-Item C:\Users\Public\Desktop\AdminCenter.lnk -Force -ErrorAction SilentlyContinue
$wshshell = New-Object -ComObject WScript.Shell
$lnk = $wshshell.CreateShortcut("C:\Users\Public\Desktop\AdminCenter.lnk")
$lnk.TargetPath = "%windir%\system32\mstsc.exe"
$lnk.Arguments = "/v:AdminCenter"
$lnk.Description = "AdminCenter link for Azure Stack HCI Sandbox."
$lnk.Save()

$endtime = Get-Date

$timeSpan = New-TimeSpan -Start $starttime -End $endtime


Write-Verbose "`nSuccessfully deployed the Azure Stack HCI Sandbox"

Write-Host "Deployment time was $($timeSpan.Hours) hour and $($timeSpan.Minutes) minutes." -ForegroundColor Green
 
$ErrorActionPreference = "Continue"
$VerbosePreference = "SilentlyContinue"
$WarningPreference = "Continue"

#endregion Main
