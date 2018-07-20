<#
    .SYNOPSIS
        Creates a lab environemnt contained in it's own Azure Resource Group by copying a snapshot VHD from
        a parent resource group.

    .PARAMETER LabNumber
        Specifies the number of labs to create.  The default is 1

    .PARAMETER VMSize
        Specifies the size of the Azure VM.  Possible choices are Standard_D4_v3 and Standard_D8_v3.
        The default is Standard_D4_v3

    .PARAMETER SnapshotResourceGroup
        Specifies the resource group to copy the parent snapshot from.
        The default is is parentResourceGroup.

    .PARAMETER SnapShotName
        Specifies the name of the parent snapshot VHD to copy the lab from.

    .Example
        PS C:\> Connect-AzureRmAccount

        Name             : [acdadmin@outlook.com, 1e32f512-e00a-4c31-a31f-7c84d2bc66a1]
        Account          : acdadmin@outlook.com
        SubscriptionName : Consortium Lab Azure Environment
        TenantId         : 257c335d-a2e7-5b65-9736-1a043ea0d3f7
        Environment      : AzureCloud

        PS C:\>New-ACDLab -LabNumber 5

        This example demonstrates connecting to an Azure account and then creating 5 ACD training labs

    .EXAMPLE
        PS C:\>New-ACDLab -SnapshotResourceGroup parentKaliLab -SnapShotName KaliLab

        This example demonstrates creating a training lab using a custom (non-default) parent VHD
#>
function New-ACDLab
{
    [CmdletBinding()]
    param
    (
        [Parameter(Position = 1)]
        [int]
        $LabNumber = 1,

        [Parameter(Position = 2)]
        [ValidateSet('Standard_D4_v3', 'Standard_D8_v3')]
        [string]
        $VMSize = 'Standard_D4s_v3',

        [Parameter(Position = 3)]
        [string]
        $SnapshotResourceGroup = 'parentResourceGroup',

        [Parameter(Position = 4)]
        [string]
        $SnapShotName = 'CyberLabParent'
    )

    $azureContext = Get-AzureRmContext

    # Check if a subscription is found in the context. If not, login.
    if ($null -eq $azureContext)
    {
        Connect-AzureRmAccount
    }

    $labCount = 1..$LabNumber

    foreach ($lab in $labCount)
    {
        $studentName = 'Student' + $lab
        New-AzureRmResourceGroup -Name $studentName -Location EastUS -ErrorAction Stop

        $snapShot = Get-AzureRmSnapshot -ResourceGroupName $SnapshotResourceGroup -SnapshotName $SnapShotName

        $diskConfig = New-AzureRmDiskConfig -Location $snapShot.Location -SourceResourceId $snapShot.Id -CreateOption Copy

        $disk = New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $studentName -DiskName ($studentName + 'OS')

        $virtualNetwork = New-AzureRmVirtualNetwork -ResourceGroupName $studentName -Location EastUS -Name cyberVnet -AddressPrefix '10.0.0.0/16'

        $subnetConfig = Add-AzureRmVirtualNetworkSubnetConfig -Name default -AddressPrefix '10.0.0.0/24' -VirtualNetwork $virtualNetwork
        $subnetConfig | Set-AzureRmVirtualNetwork

        $virtualMachine = New-AzureRmVMConfig -VMName HyperV -VMSize $VMSize

        $virtualMachine = Set-AzureRmVMOSDisk -VM $virtualMachine -ManagedDiskId $disk.Id -CreateOption Attach -Windows

        $publicIp = New-AzureRmPublicIpAddress -Name hyperv_ip -ResourceGroupName $studentName -Location $snapShot.Location -AllocationMethod Dynamic

        $vnet = $virtualNetwork | Get-AzureRmVirtualNetwork

        $nic = New-AzureRmNetworkInterface -Name hyperv_nic -ResourceGroupName $studentName -Location $snapShot.Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $publicIp.Id

        $virtualMachine = Add-AzureRmVMNetworkInterface -VM $virtualMachine -Id $nic.Id

        New-AzureRmVM -VM $virtualMachine -ResourceGroupName $studentName -Location $snapShot.Location -AsJob
    }

    # Wait until all labs are provisioned and then set auto-shutdown
    Get-Job | Wait-Job
    Set-ACDLabAutoShutdown
}

<#
    .SYNOPSIS
        Configures ACD training labs to automatic shutdown at the specified time.
        Current this is hard coded to 1900 Easter Standard Time.

    .PARAMETER ResourceGroupSuffix
        The Set-ACDLabAutoShutdown function will apply the auto shutdown resource to all the VMs in a specified resource.
        A regular expression is used to filter the desired resource groups to apply the auto shutdown policy to.
        The default is ^Student, which will apply the policy to all resource groups the start with "Student".

    .EXAMPLE
        PS C:\> Set-ACDLabAutoShutdown

        This example will apply the auto shutdown policy to all VMs a resource groups that starts with Student.
#>
function Set-ACDLabAutoShutdown
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $ResourceGroupSuffix = '^Student'
    )

    $resourceGroups = Get-AzureRmResourceGroup | Where-Object -Property ResourceGroupName -Match $ResourceGroupSuffix

    foreach ($resourceGroup in $resourceGroups.ResourceGroupName)
    {
        $virtualMachines = Get-AzureRmVm -ResourceGroupName $resourceGroup
        foreach ($virtualMachine in $virtualMachines)
        {
            $vmName = $virtualMachine.Name
            $shutdownTime = "1900"
            $shutdownTimezone = "Eastern Standard Time"
            $properties = @{
                "status"          = "Enabled"
                "taskType"        = "ComputeVmShutdownTask"
                "dailyRecurrence" = @{ "time" = $shutdownTime }
                "timeZoneId"      = $shutdownTimezone
                "notificationSettings" = @{
                    "status" = "Disabled"
                    "timeInMinutes" = 30
                }
                "targetResourceId" = $virtualMachine.Id
            }

            $azureRmResourceParameters = @{
                ResourceId = ("/subscriptions/{0}/resourceGroups/{1}/providers/microsoft.devtestlab/schedules/shutdown-computevm-{2}" -f (Get-AzureRmContext).Subscription.Id, $resourceGroup, $vmName)
                Location   = $virtualMachine.Location
                Properties = $properties
                Force      = $true
            }

            New-AzureRmResource @azureRmResourceParameters
        }
    }

}

<#
    .SYNOPSIS
        Removes/deletes a ACD training lab environments

    .PARAMETER ResourceGroupName
        The Remove-ACDLab function will apply the auto shutdown resource to all the VMs in a specified resource.
        A regular expression is used to filter the desired resource groups to apply the auto shutdown policy to.
        The default is ^Student, which will apply the policy to all resource groups the start with "Student".

    .EXAMPLE
        PS C:\> Remove-ACDLab -ResourceGroupName Student3

        This example will remove the lab in the Student3 resource group

    .EXAMPLE
        PS C:\>Remove-ACDLab

        This example will remove all the ACD training labs
#>
function Remove-ACDLab
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $ResourceGroupName = '^Student'
    )

    $azureContext = Get-AzureRmContext

    # Check if a subscription is found in the context. If not, login.
    if ($null -eq $azureContext)
    {
        Connect-AzureRmAccount
    }

    $resourceGroupsToDelete =  Get-AzureRmResourceGroup | Where-Object -Property ResourceGroupName -Match $ResourceGroupName

    $resourceGroupsToDelete | Remove-AzureRmResourceGroup -AsJob -Force
}

<#
    .SYNOPSIS
        Downloads the RDP file for all the provisioned ACD training labs.
        Defaults to OneDrive\CyberLab

    .EXAMPLE
        PS C:\>Get-ACDLabDesktopFile

        This demonstrates how to download all the RDP files for the provisioned labs to $env:HOMEPATH\OneDrive\CyberLab

    .EXAMPLE
        PS C:\>Get-ACDLabDesktopFile -Path 'C:\labRdpFiles'

        This example is downloading the RDP files for all the provisioned labs to C:\labRdpFiles
#>
function Get-ACDLabDesktopFile
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $Path
    )

    if (-not $Path)
    {
        $oneDrivePath = Resolve-Path -Path '~\OneDrive'
        $cyberLabPath = Join-Path -Path $oneDrivePath -ChildPath 'CyberLab'
    }
    else
    {
        $cyberLabPath = $Path
    }

    if (Test-Path -Path $cyberLabPath)
    {
        $resourceGroups = Get-AzureRmResourceGroup | Where-Object -Property ResourceGroupName -Match '^Student'
        $vms = $resourceGroups | Get-AzureRmVm
        foreach ($vm in $vms)
        {
            $outputPath = Join-Path -Path $cyberLabPath -ChildPath ($vm.ResourceGroupName + '.rdp')

            $getRdpFileParameters = @{
                ResourceGroupName = $vm.ResourceGroupName
                Name = $vm.Name
                LocalPath = $outputPath
            }
            Get-AzureRmRemoteDesktopFile @getRdpFileParameters
        }
    }
    else
    {
        throw "$cyberLabPath not found"
    }
}

<#
    .SYNOPSIS
        After the lab parent VHD is updated a snapshot needs to be taken before a training lab
        can be created from it.  This function creates a new VHD snapshot.

    .PARAMETER ResourceGroupName
        Specifies the resource group name the parent VHD is in.
        The default is parentResourceGroup.

    .PARAMETER VMName
        Specifies the name of the parent VM the snapshot is taken from.
        The default is LabParent

    .EXAMPLE
        PS C:\>New-ACDLabSnapShot

        This examples shows how to create a new snapshot with default parameter values.

    .EXAMPLE
        PS C:\>New-ACDLabSnapshot -ResourceGroupName KaliLab -VMName KaliLab

        This example creates a VHD snapshot from the KaliLab resource group,
        with the KaliParent VM
#>
function New-ACDLabSnapshot
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $ResourceGroupName = 'parentResourceGroup',

        [Parameter()]
        [string]
        $VMName = 'LabParent'
    )

    $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName

    $snapShot = New-AzureRmSnapshotConfig -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id -Location EastUS -CreateOption Copy

    New-AzureRmSnapshot -Snapshot $snapShot -SnapshotName CyberLabParent -ResourceGroupName $ResourceGroupName
}

<#
    .SYNOPSIS
        Shuts down an ACD training lab

    .PARAMETER ResourceGroupName
        Specifies the resource group of lab name to shutdown.
        The default is Student

    .Example
        PS C:\>Stop-ACDLab -ResourceGroupName Student3

        This example turn off the lab for Student3

    .Example
        PS C:\>Stop-ACDLab

        When ran without arguments (default) all training labs will be turned off

#>
function Stop-ACDLab
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]
        $ResourceGroupName = '^Student'
    )

    Get-AzureRmResourceGroup | Where-Object -Property ResourceGroupName -Match $ResourceGroupName | Get-AzureRmVm | Stop-AzureRmVM -AsJob -Force
}
