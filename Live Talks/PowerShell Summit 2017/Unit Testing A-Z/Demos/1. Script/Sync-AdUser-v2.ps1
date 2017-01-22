## This version is when your manager asks you to add members to a group and also disable and move
## users that are NOT on the CSV list to a specific OU. Also, need to make the script check the
## FirstInitial/MiddleInitial/LastName because it hasn't been finding some users. Also 

<#
	New requirements:

	- Add users to departmental groups
	- Disable users not in the CSV
	- Add to specific OUs depending on department.

#>

$domainDn = (Get-ADDomain).DistinguishedName

$artifactsFolder = "$($PSScriptRoot | Split-Path -Parent)\Artifacts"

## The default password for account was saved on the file system previously
$defaultPasswordXmlFile = "$artifactsFolder\DefaultUserPassword.xml"
## To save a new password, do this: Get-Credential -UserName 'DOESNOTMATTER' | Export-CliXml $defaultPasswordXmlFile
Write-Verbose -Message "Reading default password from [$("$artifactsFolder\DefaultUserPassword.xml")]..."
$defaultCredential = Import-CliXml -Path $defaultPasswordXmlFile
$defaultPassword = $defaultCredential.GetNetworkCredential().Password
$defaultPassword = (ConvertTo-SecureString $defaultPassword -AsPlainText -Force)

## Read the CSV
$employeesCsvPath = "$artifactsFolder\Employees.csv"
if (-not (Test-Path -Path $employeesCsvPath)) {
	throw "The employee CSV file at [$($employeesCsvPath)] could not be found."
} else {
	Write-Verbose -Message "The employee CSV file at [$($employeesCsvPath)] exists."
}

$employees = Import-Csv -Path $employeesCsvPath

if ($employees) { ## Checking to see if there was actually any employees in the CSV
	foreach ($employee in $employees)
	{
		try
		{
			## Our standard username pattern is <FirstInitial><LastName>
			$firstInitial = $employee.FirstName.SubString(0,1)
			$userName = '{0}{1}' -f $firstInitial,$employee.LastName
			
			## Check to see if the username is available
			Write-Verbose -Message "Checking if [$($userName)] is available"
			if (Get-ADUser -Filter "Name -eq '$userName'")
			{
				Write-Warning -Message "The username [$($userName)] is not available. Cannot create account."
			}
			else
			{
				Write-Verbose -Message "The username [$($userName)] is available."
				$newUserParams = @{
					UserPrincipalName = $userName
					Name = $userName
					GivenName = $employee.FirstName
					Surname = $employee.LastName
					Title = $employee.Title
					Department = $employee.Department
					SamAccountName = $userName
					AccountPassword = $defaultPassword
					Enabled = $true
					ChangePasswordAtLogon = $true
				}
				
				## v2 Addition -- Add users to specific OUs depending on department

				## Does the departmental OU even exist yet?
				$departmentOuPath = "OU=$($employee.Department),$domainDn"
				if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$departmentOuPath'")) {
					## if not, throw an error
					throw "Unable to find the OU [$($departmentOuPath)]."
				} else {
					Write-Verbose -Message "Adding [$($userName)] to the OU [$($departmentOuPath)]..."
					$newUserParams.Path = $departmentOuPath
				}

				## Create the user account with the details from the CSV
				Write-Verbose -Message "Creating the new user account [$($userName)]..."
				New-AdUser @newUserParams
			}

			##v2 Addition -- Adding to department group

			## Check to see if the group exists
			if (-not (Get-ADGroup -Filter "Name -eq '$($employee.Department)'")) {
				throw "Unable to find the group [$($employee.Department)]"
			} else {
				## If so, check to see if the user is already a member
				$groupMembers = (Get-ADGroupMember -Identity $employee.Department).Name
				if (-not ($userName -in $groupMembers)) {
					## Add the username to the department group
					Write-Verbose -Message "Adding [$($userName)] to the group [$($employee.Department)]"
					Add-ADGroupMember -Identity $employee.Department -Members $userName
				} else {
					Write-Verbose -Message "[$($userName)] is already a member of [$($employee.Department)]"
				}
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}
else
{
	Write-Warning "No records found in the file [$($employeesCsvPath)]"	
}

##v2 Addition -- Disable users to another OU not in the CSV
$adUsers = Get-ADuser -Filter "Enabled -eq 'True' -and SamAccountName -ne 'Administrator'"
$employeeUserNames = $employees.foreach({
	$firstInitial = $_.FirstName.SubString(0,1)
	'{0}{1}' -f $firstInitial,$_.LastName
 })

$nonEmployeeAdUsers = $adUsers.where({ $_.samAccountName -notin $employeeUserNames })
foreach ($emp in $nonEmployeeAdUsers) {
	$emp | Disable-AdAccount
}