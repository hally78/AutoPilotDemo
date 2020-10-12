[cmdletbinding()]
param (
    [string]$NIC1IPAddress,
    [string]$NIC2IPAddress,
    [string]$GhostedSubnetPrefix,
    [string]$VirtualNetworkPrefix,
    [string]$ClientID,
    [string]$ClientSecret,
    [string]$Tenant,
	[string]$imageUrl
)

function Create-VM {
<#
.SYNOPSIS
This function is used to create a hyper-v VM
.DESCRIPTION
Create a Hyper-V VM. Change the parameters inside the function to customize the VM. At the end of the fucntion TPM is set and
boot disk is replace with gold image
#>
param
(
    [Parameter(Mandatory=$true)][string]$VMN,
    [parameter(Mandatory=$true)][string]$bootIMG
)

$NewVMParam = @{
  Name = $VMN
  Generation = 2
  MemoryStartUpBytes = 1GB
  Path = "c:\VMs"
  SwitchName =  "NestedSwitch"
  NewVHDPath =  "f:\VMs\$VMN\boot.vhdx"
  NewVHDSizeBytes =  50GB 
  ErrorAction =  'Stop'
  Verbose =  $True
  }

  $SetVMParam = @{
  ProcessorCount =  2
  DynamicMemory =  $True
  MemoryMinimumBytes =  1GB
  MemoryMaximumBytes =  3Gb
  ErrorAction =  'Stop'
  PassThru =  $True
  Verbose =  $True
  }

$VM = New-VM @NewVMParam 
$VM = $VM | Set-VM @SetVMParam 


Set-VMKeyProtector -VMName $VMN -NewLocalKeyProtector
Enable-VMTPM -VMName $VMN

##### Copy gold image
$dst="F:\VMs\$VMN\boot.vhdx"
Add-Content $logfile -Value "Copying Disk"
Copy-Item $bootIMG $dst
Add-Content $logfile -Value  "Starting $VMN"
Start-vm -Name $VMN
}


$logfile = "f:\APProvision.log"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

####### Import Modules 
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module Subnet -Force
Install-Module WindowsAutoPilotIntune -Force
Install-Module Microsoft.Graph.Intune -Force
Install-Module -Name 7Zip4Powershell -RequiredVersion 1.9.0 -Force
Add-Content $logfile -Value "Modules Imported"

###### Create Hyper-V infrastructure 
New-VMSwitch -Name "NestedSwitch" -SwitchType Internal

$NIC1IP = Get-NetIPAddress | Where-Object -Property AddressFamily -EQ IPv4 | Where-Object -Property IPAddress -EQ $NIC1IPAddress
$NIC2IP = Get-NetIPAddress | Where-Object -Property AddressFamily -EQ IPv4 | Where-Object -Property IPAddress -EQ $NIC2IPAddress

$NATSubnet = Get-Subnet -IP $NIC1IP.IPAddress -MaskBits $NIC1IP.PrefixLength
$HyperVSubnet = Get-Subnet -IP $NIC2IP.IPAddress -MaskBits $NIC2IP.PrefixLength
$NestedSubnet = Get-Subnet $GhostedSubnetPrefix
$VirtualNetwork = Get-Subnet $VirtualNetworkPrefix

New-NetIPAddress -IPAddress $NestedSubnet.HostAddresses[0] -PrefixLength $NestedSubnet.MaskBits -InterfaceAlias "vEthernet (NestedSwitch)"
New-NetNat -Name "NestedSwitch" -InternalIPInterfaceAddressPrefix "$GhostedSubnetPrefix"

Add-DhcpServerv4Scope -Name "Nested VMs" -StartRange $NestedSubnet.HostAddresses[1] -EndRange $NestedSubnet.HostAddresses[-1] -SubnetMask $NestedSubnet.SubnetMask
Set-DhcpServerv4OptionValue -DnsServer 168.63.129.16 -Router $NestedSubnet.HostAddresses[0]

Install-RemoteAccess -VpnType RoutingOnly
cmd.exe /c "netsh routing ip nat install"
cmd.exe /c "netsh routing ip nat add interface ""$($NIC1IP.InterfaceAlias)"""
cmd.exe /c "netsh routing ip add persistentroute dest=$($NatSubnet.NetworkAddress) mask=$($NATSubnet.SubnetMask) name=""$($NIC1IP.InterfaceAlias)"" nhop=$($NATSubnet.HostAddresses[0])"
cmd.exe /c "netsh routing ip add persistentroute dest=$($VirtualNetwork.NetworkAddress) mask=$($VirtualNetwork.SubnetMask) name=""$($NIC2IP.InterfaceAlias)"" nhop=$($HyperVSubnet.HostAddresses[0])"

Get-Disk | Where-Object -Property PartitionStyle -EQ "RAW" | Initialize-Disk -PartitionStyle GPT -PassThru | New-Volume -FileSystem NTFS -AllocationUnitSize 65536 -DriveLetter F -FriendlyName "Hyper-V"

Add-Content $logfile -Value "Hyper-V infra created"


####### Download and extract Gold image
########################################
$vmname = "Win10AutoPilot01"
$workfolder = "f:\VMs"
$imageFile ="f:\VMs\bootgold.7z"

New-Item -ItemType Directory -Path $workfolder -Force
Set-Location $workfolder
(New-Object System.Net.WebClient).DownloadFile($imageUrl, $imageFile)
Expand-7Zip -ArchiveFileName $imageFile -TargetPath $workfolder

######## Create autopilot nested VM
###################################
Create-VM -bootIMG "F:\VMs\boot-gold.vhdx" -VMN $vmname
Add-Content $logfile -Value "VM Created"


####### Import Modules 
######################
Import-Module -Name WindowsAutoPilotIntune -ErrorAction Stop
Import-Module -Name Microsoft.Graph.Intune 
$user="marco"
$pass ='@MegaP@$$W0rd!%&'
$secpassword = ConvertTo-SecureString $pass -AsPlainText -Force
$localcred = New-Object -TypeName System.Management.Automation.PSCredential ( $user, $secpassword)
$authority = "https://login.windows.net/$Tenant"

######## Connect to MS Graph
############################
Update-MSGraphEnvironment -AppId $ClientID -Quiet
Update-MSGraphEnvironment -AuthUrl $authority -Quiet
Connect-MSGraph -ClientSecret $ClientSecret -Quiet


####### Get a PS Session with the nested VM
###########################################

$session =$null
while ( $session -eq $null) {
    $session = New-PSSession -Credential $localcred -VMName $vmname -ErrorAction Ignore
    if ($session) { break}
    Add-Content $logfile -Value  "PS Session not ready. Retrying in 1 min "
    Start-Sleep -Seconds 60 
}


######## Get HWInfo from the nested VM
######################################

$d =Invoke-Command -Session $session -command  { c:\powershell\get-ap-info.ps1 }  
Add-AutoPilotImportedDevice  -serialNumber $d.'Device Serial Number' -hardwareIdentifier $d.'Hardware Hash' -orderIdentifier "VMs"
Start-Sleep 20

Add-Content $logfile -Value  $d.'Device Serial Number'

#### Import AutoPilot Device in Intune
######################################
$impdev = $null 
while ( $impdev -eq $null ){
try{
$impdev = ( Get-AutoPilotDevice  |?{$_.serialNumber -eq $d.'Device Serial Number'}) 
}
catch{}

if($impdev) 
{
 Add-Content $logfile -Value  "Device has been Imported"
 break
 }
Add-Content $logfile -Value  "Device has not been imported yet. Sleeping 2 min"
Invoke-AutopilotSync
Start-Sleep -Seconds 120 
}

#### Wait for AP profile to be assigned 
#######################################

$ProfileAssigned ="notAssigned"
while (($ProfileAssigned -like "notAssigned") -or ($ProfileAssigned -like "*pending*")){
    try{
        $ProfileAssigned =  (Get-AutoPilotDevice|?{$_.serialNumber -eq $d.'Device Serial Number'}).deploymentProfileAssignmentStatus
        }
    catch{
    }
    Add-Content $logfile -Value  "Profile has not been assigned yet. Sleeping 1 min"
    Start-Sleep -Seconds 60 
}

Add-Content $logfile -Value "Profile assigned"

### reset the nested autopilot device 
 Write-Output "Invoking remote wipe of $VMName"
Invoke-Command -Session $session -command  { c:\powershell\startwipe.bat } 
