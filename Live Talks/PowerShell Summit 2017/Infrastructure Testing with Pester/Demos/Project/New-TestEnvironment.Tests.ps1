<#
    .SYNOPSIS
        This is a set of Pester tests for for New-TestEnvironment script.

    .PARAMETER Full
         An optional switch parameter that is used if a full, from-scratch set of tests is to be executed. This accounts
         for dependencies, executes the code to be tested and tears down any changes made. Use this switch if you don't
         trust the current environment configuration and want to start from scratch.

    .PARAMETER DependencyFailureAction
         An optional string parameter representing the action to take if any test dependencies are not found. This can
         either be 'Exit' which if a dependency is not found, the tests will exit or 'Build' which indicates to dynamically
         build any dependencies required and tear them down after the tests are complete.

    .EXAMPLE
        PS> Invoke-Pester -Script @{ Parameter = @{ Path = 'New-TestEnvironment.Tests.ps1'}}

            This example executes this test suite assuming that the code that builds the components for these tests
            was already ran and the dependencies required for these tests to execute are already in place.

    .EXAMPLE
        PS> Invoke-Pester -Script @{ Parameter = @{ Path = 'New-TestEnvironment.Tests.ps1'; Parameter = @{ Full = $true }}}

            This example executes this test suite assuming nothing. It will start from scratch by first checking to see
            if all prerequiiste dependencies are in place. If not, it will dynamically build them. It will execute the 
            code to be tested, perform all necessary tests against the infrastructure and then tear down any dependencies
            and changes that the tests performed.

#>

param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [switch]$Full,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('Exit','Build')]
    [string]$DependencyFailureAction = 'Exit'
)

describe 'TestEnvironment' {

    $expectedDomainControllerName = @($expectedAttributes.AllNodes[0]).where({ $_.Purpose -eq 'Domain Controller' -and $_.NodeName -ne '*' }).Nodename
    $expectedVmName = $expectedDomainControllerName
    $hyperVSrv = 'HYPERVSRV'
    
    if ($Full.IsPresent) {

        #region Dependency checking and remediation
            $hyperVCred = (Import-Clixml -Path "$PSScriptRoot\HyperVCredential.xml")

            ## Check all dependencies. These are ordered for a reason.
            $dependencies = [ordered]@{
                'VM is created' = @{
                    CheckAction = {
                        $vmCheck = { 
                            if (Get-VM -Name $using:expectedVmName -ErrorAction 'SilentlyContinue') {
                                $true
                            }  else {
                                $false
                            }
                        }
                        Invoke-Command -ComputerName $hyperVSrv -ScriptBlock $vmCheck 
                    }
                    RemediationAction = {
                        throw 'VM creation remediation code not yet implemented. Laziness in full effect.'
                    }
                    RemoveAction = {
                        throw 'VM creation removal code not yet implemented. Laziness in full effect.'
                    }
                }
                'VM is running' = @{
                    CheckAction = {
                        $vmCheck = { 
                            if (Get-VM -Name $using:expectedVmName -ErrorAction 'SilentlyContinue' | where { $_.State -eq 'Running' }) {
                                $true
                            }  else {
                                $false
                            }
                        }
                        Invoke-Command -ComputerName $hyperVSrv -ScriptBlock $vmCheck 
                    }
                    RemediationAction = {
                        Invoke-Command -ComputerName $hyperVSrv -ScriptBlock { Get-VM -Name $using:expectedVmName | Start-Vm }
                    }
                    RemoveAction = {
                        Invoke-Command -ComputerName $hyperVSrv -ScriptBlock { Get-VM -Name $using:expectedVmName | Stop-Vm }
                    }
                }
                'VM can be found by name' = @{
                    CheckAction = {
                        (Resolve-DnsName -Name $expectedDomainControllerName -ErrorAction 'SilentlyContinue') -ne $null
                    }
                    RemediationAction = {
                        Write-Warning -Message 'No specific remediation necessary for DNS problem. You have probably got bigger problems.'
                    }
                    RemoveAction = {
                        Write-Verbose -Message 'No specific remove action necessary for DNS problem.'
                    }  
                }
                'VM is pingable' = @{
                    CheckAction = {
                        Test-Connection -Name $expectedDomainControllerName -Quiet -Count 1
                    }
                    RemediationAction = {
                        throw 'VM is running but it is not pingable. This is where I might do something to the VM firewall.'
                    }
                    RemoveAction = {
                        Write-Verbose -Message 'No specific remove action necessary for unpingable (is that a word?) VM.'
                    }
                    
                }
                'VM has PS Remoting available' = @{
                    CheckAction = {
                        (Invoke-Command  -ComputerName $expectedDomainControllerName -ScriptBlock {1}) -eq 1
                    }
                    RemediationAction = {
                        throw 'VM cannot be remoted to. This is where I might try to enable WinRM.'
                    }
                    RemoveAction = {
                        Write-Verbose -Message 'No specific remove action necessary for unresponsive PS remoting VM.'
                    }
                }
            }

            $script:removeActions = @()
            foreach ($dep in $dependencies.GetEnumerator()) {
                if (-not (& $dep.Value.CheckAction)) {
                    if ($DependencyFailureAction -eq 'Exit') {
                        throw "The dependency [$($dep.Key)] failed. Halting tests.."
                    } else {
                        Write-Verbose -Message "The dependency [$($dep.Key)] failed but hold on. I am remediating this..."
                        $script:removeActions += $dep.Value.RemoveAction
                        & $dep.Value.RemediationAction
                    }
                }
            }
        #endregion

        AfterAll {
            ## Tear down any dependencies created and all changes made to environment
            Write-Verbose -Message 'Cleaning up the mess...'
            & "$PSScriptRoot\Remove-TestEnvironment.ps1"

            foreach ($removeAction in $script:removeActions) {
                & $removeAction
            }
        }
    }

    ## Execute the code we're testing
    & "$PSScriptRoot\New-TestEnvironment.ps1"

    ## Run all tests
    ## Read the expected attributes from ConfigurationData
    $expectedAttributes = Import-PowerShellDataFile -Path "$PSScriptRoot\ConfigurationData.psd1"
    
    
    $sharedSession = New-PSSession -ComputerName $expectedDomainControllerName

    ## Forest-wide
    $forest = Invoke-Command -Session $sharedSession -ScriptBlock { Get-AdForest }
    
    ## Groups
    $actualGroups = Invoke-Command -Session $sharedSession -ScriptBlock {  Get-AdGroup -Filter '*' } | Select -ExpandProperty Name
    $expectedGroups = $expectedAttributes.NonNodeData.AdGroups
    
    ## OUs
    $actualOuDns = Invoke-Command -Session $sharedSession -ScriptBlock { Get-AdOrganizationalUnit -Filter '*' } | Select -ExpandProperty DistinguishedName
    $expectedOus = $expectedAttributes.NonNodeData.OrganizationalUnits
    $expectedOuDns = $expectedOus | foreach { "OU=$_,DC=mylab,DC=local" }

    ## Users
    $actualUsers = Invoke-Command -Session $sharedSession -ScriptBlock { Get-AdUser -Filter "*" -Properties Department,Title }
    $expectedUsers = $expectedAttributes.NonNodeData.AdUsers

    it "creates the expected forest" {
        $forest.Name | should be $expectedAttributes.NonNodeData.DomainName
    }

    it 'creates all expected AD Groups' {

    @($actualGroups | where { $_ -in $expectedGroups }).Count | should be @($expectedGroups).Count

    }

    it 'creates all expected AD OUs' {
        
        @($actualOuDns | where { $_ -in $expectedOuDns }).Count | should be @($expectedOuDns).Count
        
    }

    it 'creates all expected AD users' {
        
        foreach ($user in $expectedUsers) {
            $expectedUserName = ('{0}{1}' -f $user.FirstName.SubString(0,1),$user.LastName)
            $actualUserMatch = $actualUsers | where {$_.SamAccountName -eq $expectedUserName}
            $actualUserMatch | should not benullorempty     
            $actualUserMatch.givenName | should be $user.FirstName
            $actualUserMatch.surName | should be $user.LastName
            $actualUserMatch.Department | should be $user.Department
            $actualUserMatch.DistinguishedName | should be "CN=$expectedUserName,OU=$($user.Department),DC=mylab,DC=local"
        }
    }
}