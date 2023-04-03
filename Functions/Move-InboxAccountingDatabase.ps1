<#

.SYNOPSIS
    PowerShell script to relocate the DirectAccess/Routing and Remote Access Service (RRAS) inbox accounting database.

.PARAMETER SourcePath
    The original location of the Remote Access inbox accounting database. This paramter is not required if the database files are in the default location of C:\Windows\DirectAccess\db.

.PARAMETER DestinationPath
    The target location to move the Remote Access inbox accounting database to.

.PARAMETER Computername
    The name of the computer on which to run the command. Default is the local computer.

.PARAMETER Credential
    Optional credential to run the script under.

.EXAMPLE
    Move-InboxAccountingDatabase -DestinationPath 'D:\DirectAccess\db\'

    Running this command will move the Remote Access inbox accounting database from the default location of C:\Windows\DirectAccess\DB to D:\DirectAccess\DB\.'

.EXAMPLE
    Move-InboxAccountingDatabase -SourcePath 'D:\DirectAccess\db\' -DestinationPath 'E:\DirectAccess\db\'

    Running this command will move the Remote Access inbox accounting database from the custom location of D:\Windows\DirectAccess\db\ to E:\DirectAccess\db\.'

.DESCRIPTION
    When DirectAccess or VPN is enabled on a Windows Server, and inbox accounting is enabled, a Windows Internal Database (WID) is created on the system drive by default. This script allows the administrator to relocate this database to another drive to increase data retention time and improve performance.

.LINK
    https://github.com/richardhicks/InboxAccountingDatabaseManagement/blob/main/Functions/Move-InboxAccountingDatabase.ps1

.LINK
    https://directaccess.richardhicks.com/2022/03/21/inbox-accounting-database-management/

.LINK
    https://directaccess.richardhicks.com/

.NOTES
    Version:        1.0.3
    Creation Date:  March 19, 2022
    Last Updated:   December 11, 2022
    Author:         Richard Hicks
    Organization:   Richard M. Hicks Consulting, Inc.
    Contact:        rich@richardhicks.com
    Web Site:       https://www.richardhicks.com/

#>

Function Move-InboxAccountingDatabase {

    [CmdletBinding(SupportsShouldProcess)]

    Param (

        [Parameter(HelpMessage = "Enter the path to the Direct Access database folder relative to the remote computer.")]
        [Alias("Path")]
        [string]$SourcePath = "C:\Windows\DirectAccess\db",
        [Parameter(Mandatory, HelpMessage = "Enter the target folder path to move the Direct Access database relative to the remote computer.")]
        [alias("Destination")]
        [string]$DestinationPath,
        [Parameter(HelpMessage = "Enter the name of the remote RRAS server.", ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Computername = $env:computername,
        [switch]$Passthru,
        [ValidateSet('Default', 'Basic', 'Credssp', 'Digest', 'Kerberos', 'Negotiate', 'NegotiateWithImplicitCredential')]
        [ValidateNotNullorEmpty()]
        [string]$Authentication = "default",
        [switch]$UseSSL

    )

    Begin {

        Write-Verbose "Starting $($myinvocation.mycommand)"
        # // Display some meta information for troubleshooting
        Write-Verbose "PowerShell version: $($psversiontable.psversion)"
        Write-Verbose "Operating System: $((Get-Ciminstance -class win32_operatingsystem -property caption).caption)"

        $sb = {

            [cmdletbinding()]
            Param (

                [ValidateScript( {

                        # // Write a custom error message if the database file isn't in the source path
                        If (Test-Path "$_\RaAcctDb.mdf") {

                            Return $True

                        }

                        Else {

                            Throw "The path ($_) does not appear to contain the RaAcctDB.mdf database."

                        }

                    })]

                [string]$SourcePath,
                [string]$DestinationPath,
                [bool]$PassThru

            )

            $VerbosePreference = $using:verbosepreference
            $whatifpreference = $using:whatifpreference
            Write-Verbose "SourcePath = $SourcePath"
            Write-Verbose "TargetPath = $DestinationPath"
            Write-Verbose "WhatIf = $whatifpreference"
            Write-verbose "Verbose = $VerbosePreference"

            If (-Not (Test-Path $DestinationPath)) {

                Write-Verbose "Creating target $DestinationPath"
                Try {

                    New-Item -ItemType Directory -Force -Path $DestinationPath -ErrorAction Stop | Out-Null

                }

                Catch {

                    Write-Verbose "Failed to create target folder $DestinationPath"
                    Throw $_

                    # // This should terminate the command if the target folder can't be created.
                    # // We will force a bailout just in case this doesn't terminate.

                    Return

                }

            }

            Write-Verbose "Copying Access Control from $SourcePath to $DestinationPath..."

            If ($pscmdlet.ShouldProcess($DestinationPath, "Copy Access Control")) {

                Try {

                    Write-Verbose "Get ACL..."
                    $Acl = Get-Acl -Path $SourcePath -ErrorAction stop
                    Write-Verbose "Set ACL..."
                    Set-Acl -Path $DestinationPath -aclobject $Acl -ErrorAction stop

                }

                Catch {

                    Write-Verbose "Failed to copy ACL from $SourcePath to $DestinationPath."
                    Throw $_
                    # //Bail out if PowerShell doesn't terminate the pipeline
                    Return

                }

            } # // WhatIf copying ACL

            Write-Verbose "Stopping the RemoteAccess Management service..."

            Try {

                Get-Service -Name RaMgmtSvc -ErrorAction Stop | Stop-Service -Force -ErrorAction Stop

            }

            Catch {

                Write-Verbose "Failed to stop the RemoteAccess Management service."
                Throw $_
                # // Bail out if PowerShell doesn't terminate the pipeline
                Return

            }

            Write-Verbose "Altering database..."
            $sqlConn = 'server=\\.\pipe\Microsoft##WID\tsql\query;Database=RaAcctDb;Trusted_Connection=True;'
            $Connection = New-Object System.Data.SQLClient.SQLConnection($sqlConn)
            Write-Verbose "Opening database connection..."

            If ($pscmdlet.ShouldProcess("RaAcctDB", "Open Connection")) {

                $Connection.Open()

            }

            $Command = $Connection.CreateCommand()
            $CommandText = "USE master;ALTER DATABASE RaAcctDb SET SINGLE_USER WITH ROLLBACK IMMEDIATE;EXEC sp_detach_db @dbname = N'RaAcctDb';"
            Write-Verbose $CommandText
            $Command.CommandText = $CommandText
            $Command | Out-String | Write-Verbose

            If ($pscmdlet.ShouldProcess("RaAcctDB", "ALTER DATABASE")) {

                Write-Verbose "Executing..."
                $rdrDetach = $Command.ExecuteReader()
                Write-Verbose "Database detached."
                $rdrDetach | Out-String | Write-Verbose

            }

            Write-Verbose "Closing the database connection..."

            If ($Connection.State -eq "Open") {

                $Connection.Close()

            }

            Write-Verbose "Moving database files from $sourcePath to $DestinationPath..."
            $Mdf = Join-Path -path $SourcePath -ChildPath "RaAcctDb.mdf"
            $Ldf = Join-Path -path $SourcePath -ChildPath "RaAcctDb_log.ldf"
            Move-Item -Path $Mdf -Destination $DestinationPath
            Move-Item -Path $Ldf -Destination $DestinationPath

            Write-Verbose "Creating new database..."
            $sqlConn = 'server=\\.\pipe\Microsoft##WID\tsql\query;Database=;Trusted_Connection=True;'
            $Connection = New-Object System.Data.SQLClient.SQLConnection($sqlConn)
            Write-Verbose "Opening database connection..."

            If ($pscmdlet.ShouldProcess("New DB", "Open Connection")) {

                $Connection.Open()

            }

            $Command = $Connection.CreateCommand()
            $targetmdf = Join-Path -Path $DestinationPath -ChildPath RaAcctDb.mdf
            $targetldf = Join-Path -Path $DestinationPath -ChildPath RaAcctDb_log.ldf
            $CommandText = "USE master CREATE DATABASE RaAcctDb ON (FILENAME = '$targetmdf'),(FILENAME = '$targetldf') FOR ATTACH;USE [master] ALTER DATABASE [RaAcctDb] SET READ_WRITE WITH NO_WAIT;"
            Write-Verbose $CommandText
            $Command.CommandText = $CommandText

            If ($pscmdlet.ShouldProcess($targetmdf, "CREATE DATABASE")) {

                Write-Verbose "Executing..."
                $rdrAttach = $Command.ExecuteReader()
                Write-Verbose "Database attached."
                $rdrAttach | Out-String | Write-Verbose

            }

            Write-Verbose "Closing WID connection..."

            If ($Connection.State -eq "Open") {

                $Connection.Close()

            }

            Write-Verbose "Starting the RemoteAccess Management Service..."

            Try {

                Get-Service -Name RaMgmtSvc -ErrorAction stop | Start-Service -ErrorAction stop

            }

            Catch {

                Write-Verbose "Failed to start RemoteAccess Management service."
                Throw $_

            }

            #// Manage README.txt file
            If ($SourcePath -eq "C:\Windows\DirectAccess\db") {

                # // Create a readme.txt file in the default location if files are being moved.

                $txt = @"
The inbox accounting database and log files have been relocated to $DestinationPath.
The move was performed by $env:USERDOMAIN\$env:USERNAME on $((Get-Date).ToShortDateString()) at $((Get-Date).ToShortTimeString()).
"@

                Set-Content -Path C:\Windows\DirectAccess\DB\readme.txt -Value $txt

            }

            ElseIf ($DestinationPath -eq "C:\Windows\DirectAccess\db" -AND (Test-Path -path "C:\Windows\DirectAccess\db\readme.txt") ) {

                #// If the destination is the default location and the readme file exists, delete the file.
                Remove-Item -Path "C:\Windows\DirectAccess\db\readme.txt"

            }

            If ($Passthru) {

                Get-ChildItem -Path $DestinationPath

            }

        } #// Close scriptblock

        # // Define a set of parameter values to splat to Invoke-Command
        $icmParams = @{

            Computername     = ""
            Scriptblock      = $sb
            HideComputername = $True
            Authentication   = $Authentication
            ArgumentList     = @($SourcePath, $DestinationPath, $Passthru)
            ErrorAction      = "Stop"

        }

        If ($pscredential.username) {

            Write-Verbose "Adding an alternate credential for $($pscredential.username)..."
            $icmParams.Add("Credential", $PSCredential)

        }

        If ($UseSSL) {

            Write-Verbose "Using SSL."
            $icmParams.Add("UseSSL", $True)

        }

        Write-Verbose "Using $Authentication authentication."

    } # // Begin

    Process {

        ForEach ($Computer in $Computername) {

            Write-Verbose "Querying $($computer.toUpper())..."
            $icmParams.Computername = $Computer
            $icmParams | Out-String | Write-Verbose

            Try {

                # //Display result without the runspace ID
                Invoke-Command @icmParams

            }

            Catch {

                Throw $_

            }

        } #// Foreach computer

    } # // Process

    End {

        Write-Verbose "Ending $($myinvocation.MyCommand)"

    } #end

}

# SIG # Begin signature block
# MIInGQYJKoZIhvcNAQcCoIInCjCCJwYCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUkm6LjXJunmiVdJKN/wuf0cdm
# ycWggiDBMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
# AQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz
# 7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS
# 5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7
# bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfI
# SKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jH
# trHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14
# Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2
# h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt
# 6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPR
# iQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ER
# ElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4K
# Jpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAd
# BgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SS
# y4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAC
# hjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURS
# b290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRV
# HSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyh
# hyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO
# 0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo
# 8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++h
# UD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5x
# aiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGrjCCBJag
# AwIBAgIQBzY3tyRUfNhHrP0oZipeWzANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQG
# EwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNl
# cnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQwHhcNMjIw
# MzIzMDAwMDAwWhcNMzcwMzIyMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQg
# UlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAxoY1BkmzwT1ySVFVxyUDxPKRN6mXUaHW0oPRnkyibaCw
# zIP5WvYRoUQVQl+kiPNo+n3znIkLf50fng8zH1ATCyZzlm34V6gCff1DtITaEfFz
# sbPuK4CEiiIY3+vaPcQXf6sZKz5C3GeO6lE98NZW1OcoLevTsbV15x8GZY2UKdPZ
# 7Gnf2ZCHRgB720RBidx8ald68Dd5n12sy+iEZLRS8nZH92GDGd1ftFQLIWhuNyG7
# QKxfst5Kfc71ORJn7w6lY2zkpsUdzTYNXNXmG6jBZHRAp8ByxbpOH7G1WE15/teP
# c5OsLDnipUjW8LAxE6lXKZYnLvWHpo9OdhVVJnCYJn+gGkcgQ+NDY4B7dW4nJZCY
# OjgRs/b2nuY7W+yB3iIU2YIqx5K/oN7jPqJz+ucfWmyU8lKVEStYdEAoq3NDzt9K
# oRxrOMUp88qqlnNCaJ+2RrOdOqPVA+C/8KI8ykLcGEh/FDTP0kyr75s9/g64ZCr6
# dSgkQe1CvwWcZklSUPRR8zZJTYsg0ixXNXkrqPNFYLwjjVj33GHek/45wPmyMKVM
# 1+mYSlg+0wOI/rOP015LdhJRk8mMDDtbiiKowSYI+RQQEgN9XyO7ZONj4KbhPvbC
# dLI/Hgl27KtdRnXiYKNYCQEoAA6EVO7O6V3IXjASvUaetdN2udIOa5kM0jO0zbEC
# AwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFLoW2W1N
# hS9zKXaaL3WMaiCPnshvMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/nupiuHA9P
# MA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3BggrBgEFBQcB
# AQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggr
# BgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1
# c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2NybDMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAI
# BgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQB9WY7Ak7Zv
# mKlEIgF+ZtbYIULhsBguEE0TzzBTzr8Y+8dQXeJLKftwig2qKWn8acHPHQfpPmDI
# 2AvlXFvXbYf6hCAlNDFnzbYSlm/EUExiHQwIgqgWvalWzxVzjQEiJc6VaT9Hd/ty
# dBTX/6tPiix6q4XNQ1/tYLaqT5Fmniye4Iqs5f2MvGQmh2ySvZ180HAKfO+ovHVP
# ulr3qRCyXen/KFSJ8NWKcXZl2szwcqMj+sAngkSumScbqyQeJsG33irr9p6xeZmB
# o1aGqwpFyd/EjaDnmPv7pp1yr8THwcFqcdnGE4AJxLafzYeHJLtPo0m5d2aR8XKc
# 6UsCUqc3fpNTrDsdCEkPlM05et3/JWOZJyw9P2un8WbDQc1PtkCbISFA0LcTJM3c
# HXg65J6t5TRxktcma+Q4c6umAU+9Pzt4rUyt+8SVe+0KXzM5h0F4ejjpnOHdI/0d
# KNPH+ejxmF/7K9h+8kaddSweJywm228Vex4Ziza4k9Tm8heZWcpw8De/mADfIBZP
# J/tgZxahZrrdVcA6KYawmKAr7ZVBtzrVFZgxtGIJDwq9gdkT/r+k0fNX2bwE+oLe
# Mt8EifAAzV3C+dAjfwAL5HYCJtnwZXZCpimHCUcr5n8apIUP/JiW9lVUKx+A+sDy
# Divl1vupL0QVSucTDh3bNzgaoSv27dZ8/DCCBrAwggSYoAMCAQICEAitQLJg0pxM
# n17Nqb2TrtkwDQYJKoZIhvcNAQEMBQAwYjELMAkGA1UEBhMCVVMxFTATBgNVBAoT
# DERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UE
# AxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4XDTIxMDQyOTAwMDAwMFoXDTM2
# MDQyODIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJ
# bmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IENvZGUgU2lnbmluZyBS
# U0E0MDk2IFNIQTM4NCAyMDIxIENBMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBANW0L0LQKK14t13VOVkbsYhC9TOM6z2Bl3DFu8SFJjCfpI5o2Fz16zQk
# B+FLT9N4Q/QX1x7a+dLVZxpSTw6hV/yImcGRzIEDPk1wJGSzjeIIfTR9TIBXEmtD
# mpnyxTsf8u/LR1oTpkyzASAl8xDTi7L7CPCK4J0JwGWn+piASTWHPVEZ6JAheEUu
# oZ8s4RjCGszF7pNJcEIyj/vG6hzzZWiRok1MghFIUmjeEL0UV13oGBNlxX+yT4Us
# SKRWhDXW+S6cqgAV0Tf+GgaUwnzI6hsy5srC9KejAw50pa85tqtgEuPo1rn3MeHc
# reQYoNjBI0dHs6EPbqOrbZgGgxu3amct0r1EGpIQgY+wOwnXx5syWsL/amBUi0nB
# k+3htFzgb+sm+YzVsvk4EObqzpH1vtP7b5NhNFy8k0UogzYqZihfsHPOiyYlBrKD
# 1Fz2FRlM7WLgXjPy6OjsCqewAyuRsjZ5vvetCB51pmXMu+NIUPN3kRr+21CiRshh
# WJj1fAIWPIMorTmG7NS3DVPQ+EfmdTCN7DCTdhSmW0tddGFNPxKRdt6/WMtyEClB
# 8NXFbSZ2aBFBE1ia3CYrAfSJTVnbeM+BSj5AR1/JgVBzhRAjIVlgimRUwcwhGug4
# GXxmHM14OEUwmU//Y09Mu6oNCFNBfFg9R7P6tuyMMgkCzGw8DFYRAgMBAAGjggFZ
# MIIBVTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBRoN+Drtjv4XxGG+/5h
# ewiIZfROQjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8B
# Af8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwdwYIKwYBBQUHAQEEazBpMCQG
# CCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQQYIKwYBBQUHMAKG
# NWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290
# RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMBwGA1UdIAQVMBMwBwYFZ4EMAQMw
# CAYGZ4EMAQQBMA0GCSqGSIb3DQEBDAUAA4ICAQA6I0Q9jQh27o+8OpnTVuACGqX4
# SDTzLLbmdGb3lHKxAMqvbDAnExKekESfS/2eo3wm1Te8Ol1IbZXVP0n0J7sWgUVQ
# /Zy9toXgdn43ccsi91qqkM/1k2rj6yDR1VB5iJqKisG2vaFIGH7c2IAaERkYzWGZ
# gVb2yeN258TkG19D+D6U/3Y5PZ7Umc9K3SjrXyahlVhI1Rr+1yc//ZDRdobdHLBg
# XPMNqO7giaG9OeE4Ttpuuzad++UhU1rDyulq8aI+20O4M8hPOBSSmfXdzlRt2V0C
# FB9AM3wD4pWywiF1c1LLRtjENByipUuNzW92NyyFPxrOJukYvpAHsEN/lYgggnDw
# zMrv/Sk1XB+JOFX3N4qLCaHLC+kxGv8uGVw5ceG+nKcKBtYmZ7eS5k5f3nqsSc8u
# pHSSrds8pJyGH+PBVhsrI/+PteqIe3Br5qC6/To/RabE6BaRUotBwEiES5ZNq0RA
# 443wFSjO7fEYVgcqLxDEDAhkPDOPriiMPMuPiAsNvzv0zh57ju+168u38HcT5uco
# P6wSrqUvImxB+YJcFWbMbA7KxYbD9iYzDAdLoNMHAmpqQDBISzSoUSC7rRuFCOJZ
# DW3KBVAr6kocnqX9oKcfBnTn8tZSkP2vhUgh+Vc7tJwD7YZF9LRhbr9o4iZghurI
# r6n+lB3nYxs6hlZ4TjCCBsAwggSooAMCAQICEAxNaXJLlPo8Kko9KQeAPVowDQYJ
# KoZIhvcNAQELBQAwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJ
# bmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2
# IFRpbWVTdGFtcGluZyBDQTAeFw0yMjA5MjEwMDAwMDBaFw0zMzExMjEyMzU5NTla
# MEYxCzAJBgNVBAYTAlVTMREwDwYDVQQKEwhEaWdpQ2VydDEkMCIGA1UEAxMbRGln
# aUNlcnQgVGltZXN0YW1wIDIwMjIgLSAyMIICIjANBgkqhkiG9w0BAQEFAAOCAg8A
# MIICCgKCAgEAz+ylJjrGqfJru43BDZrboegUhXQzGias0BxVHh42bbySVQxh9J0J
# dz0Vlggva2Sk/QaDFteRkjgcMQKW+3KxlzpVrzPsYYrppijbkGNcvYlT4DotjIdC
# riak5Lt4eLl6FuFWxsC6ZFO7KhbnUEi7iGkMiMbxvuAvfTuxylONQIMe58tySSge
# TIAehVbnhe3yYbyqOgd99qtu5Wbd4lz1L+2N1E2VhGjjgMtqedHSEJFGKes+JvK0
# jM1MuWbIu6pQOA3ljJRdGVq/9XtAbm8WqJqclUeGhXk+DF5mjBoKJL6cqtKctvdP
# bnjEKD+jHA9QBje6CNk1prUe2nhYHTno+EyREJZ+TeHdwq2lfvgtGx/sK0YYoxn2
# Off1wU9xLokDEaJLu5i/+k/kezbvBkTkVf826uV8MefzwlLE5hZ7Wn6lJXPbwGqZ
# IS1j5Vn1TS+QHye30qsU5Thmh1EIa/tTQznQZPpWz+D0CuYUbWR4u5j9lMNzIfMv
# wi4g14Gs0/EH1OG92V1LbjGUKYvmQaRllMBY5eUuKZCmt2Fk+tkgbBhRYLqmgQ8J
# JVPxvzvpqwcOagc5YhnJ1oV/E9mNec9ixezhe7nMZxMHmsF47caIyLBuMnnHC1mD
# jcbu9Sx8e47LZInxscS451NeX1XSfRkpWQNO+l3qRXMchH7XzuLUOncCAwEAAaOC
# AYswggGHMA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATAf
# BgNVHSMEGDAWgBS6FtltTYUvcyl2mi91jGogj57IbzAdBgNVHQ4EFgQUYore0GH8
# jzEU7ZcLzT0qlBTfUpwwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2NybDMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0UlNBNDA5NlNIQTI1NlRpbWVTdGFt
# cGluZ0NBLmNybDCBkAYIKwYBBQUHAQEEgYMwgYAwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBYBggrBgEFBQcwAoZMaHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0UlNBNDA5NlNIQTI1NlRpbWVT
# dGFtcGluZ0NBLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAVaoqGvNG83hXNzD8deNP
# 1oUj8fz5lTmbJeb3coqYw3fUZPwV+zbCSVEseIhjVQlGOQD8adTKmyn7oz/AyQCb
# Ex2wmIncePLNfIXNU52vYuJhZqMUKkWHSphCK1D8G7WeCDAJ+uQt1wmJefkJ5ojO
# fRu4aqKbwVNgCeijuJ3XrR8cuOyYQfD2DoD75P/fnRCn6wC6X0qPGjpStOq/CUkV
# NTZZmg9U0rIbf35eCa12VIp0bcrSBWcrduv/mLImlTgZiEQU5QpZomvnIj5EIdI/
# HMCb7XxIstiSDJFPPGaUr10CU+ue4p7k0x+GAWScAMLpWnR1DT3heYi/HAGXyRkj
# gNc2Wl+WFrFjDMZGQDvOXTXUWT5Dmhiuw8nLw/ubE19qtcfg8wXDWd8nYiveQclT
# uf80EGf2JjKYe/5cQpSBlIKdrAqLxksVStOYkEVgM4DgI974A6T2RUflzrgDQkfo
# QTZxd639ouiXdE4u2h4djFrIHprVwvDGIqhPm73YHJpRxC+a9l+nJ5e6li6FV8Bg
# 53hWf2rvwpWaSxECyIKcyRoFfLpxtU56mWz06J7UWpjIn7+NuxhcQ/XQKujiYu54
# BNu90ftbCqhwfvCXhHjjCANdRyxjqCU4lwHSPzra5eX25pvcfizM/xdMTQCi2NYB
# DriL7ubgclWJLCcZYfZ3AYwwggcCMIIE6qADAgECAhABZnISBJVCuLLqeeLTB6xE
# MA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2Vy
# dCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25p
# bmcgUlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjExMjAyMDAwMDAwWhcNMjQx
# MjIwMjM1OTU5WjCBhjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCkNhbGlmb3JuaWEx
# FjAUBgNVBAcTDU1pc3Npb24gVmllam8xJDAiBgNVBAoTG1JpY2hhcmQgTS4gSGlj
# a3MgQ29uc3VsdGluZzEkMCIGA1UEAxMbUmljaGFyZCBNLiBIaWNrcyBDb25zdWx0
# aW5nMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA6svrVqBRBbazEkrm
# htz7h05LEBIHp8fGlV19nY2gpBLnkDR8Mz/E9i1cu0sdjieC4D4/WtI4/NeiR5id
# tBgtdek5eieRjPcn8g9Zpl89KIl8NNy1UlOWNV70jzzqZ2CYiP/P5YGZwPy8Lx5r
# IAOYTJM6EFDBvZNti7aRizE7lqVXBDNzyeHhfXYPBxaQV2It+sWqK0saTj0oNA2I
# u9qSYaFQLFH45VpletKp7ded2FFJv2PKmYrzYtax48xzUQq2rRC5BN2/n7771NDf
# J0t8udRhUBqTEI5Z1qzMz4RUVfgmGPT+CaE55NyBnyY6/A2/7KSIsOYOcTgzQhO4
# jLmjTBZ2kZqLCOaqPbSmq/SutMEGHY1MU7xrWUEQinczjUzmbGGw7V87XI9sn8Ec
# WX71PEvI2Gtr1TJfnT9betXDJnt21mukioLsUUpdlRmMbn23or/VHzE6Nv7Kzx+t
# A1sBdWdC3Mkzaw/Mm3X8Wc7ythtXGBcLmBagpMGCCUOk6OJZAgMBAAGjggIGMIIC
# AjAfBgNVHSMEGDAWgBRoN+Drtjv4XxGG+/5hewiIZfROQjAdBgNVHQ4EFgQUxF7d
# o+eIG9wnEUVjckZ9MsbZ+4kwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsG
# AQUFBwMDMIG1BgNVHR8Ega0wgaowU6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIw
# MjFDQTEuY3JsMFOgUaBPhk1odHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNl
# cnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDA+
# BgNVHSAENzA1MDMGBmeBDAEEATApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRp
# Z2ljZXJ0LmNvbS9DUFMwgZQGCCsGAQUFBwEBBIGHMIGEMCQGCCsGAQUFBzABhhho
# dHRwOi8vb2NzcC5kaWdpY2VydC5jb20wXAYIKwYBBQUHMAKGUGh0dHA6Ly9jYWNl
# cnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENvZGVTaWduaW5nUlNB
# NDA5NlNIQTM4NDIwMjFDQTEuY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQEL
# BQADggIBAEvHt/OKalRysHQdx4CXSOcgoayuFXWNwi/VFcFr2EK37Gq71G4AtdVc
# WNLu+whhYzfCVANBnbTa9vsk515rTM06exz0QuMwyg09mo+VxZ8rqOBHz33xZyCo
# Ttw/+D/SQxiO8uQR0Oisfb1MUHPqDQ69FTNqIQF/RzC2zzUn5agHFULhby8wbjQf
# Ut2FXCRlFULPzvp7/+JS4QAJnKXq5mYLvopWsdkbBn52Kq+ll8efrj1K4iMRhp3a
# 0n2eRLetqKJjOqT335EapydB4AnphH2WMQBHHroh5n/fv37dCCaYaqo9JlFnRIrH
# U7pHBBEpUGfyecFkcKFwsPiHXE1HqQJCPmMbvPdV9ZgtWmuaRD0EQW13JzDyoQdJ
# xQZSXJhDDL+VSFS8SRNPtQFPisZa2IO58d1Cvf5G8iK1RJHN/Qx413lj2JSS1o3w
# gNM3Q5ePFYXcQ0iPxjFYlRYPAaDx8t3olg/tVK8sSpYqFYF99IRqBNixhkyxAyVC
# k6uLBLgwE9egJg1AFoHEdAeabGgT2C0hOyz55PNoDZutZB67G+WN8kGtFYULBloR
# KHJJiFn42bvXfa0Jg1jZ41AAsMc5LUNlqLhIj/RFLinDH9l4Yb0ddD4wQVsIFDVl
# JgDPXA9E1Sn8VKrWE4I0sX4xXUFgjfuVfdcNk9Q+4sJJ1YHYGmwLMYIFwjCCBb4C
# AQEwfTBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/
# BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgQ29kZSBTaWduaW5nIFJTQTQwOTYg
# U0hBMzg0IDIwMjEgQ0ExAhABZnISBJVCuLLqeeLTB6xEMAkGBSsOAwIaBQCgeDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEW
# BBQC5DsA+vWKviRNWCySGyTE7zVeFTANBgkqhkiG9w0BAQEFAASCAYAsx3U7mtsT
# STevW3AD1LWlQNDX3TiJyJJ/AX8ceLE0mUWXyUiBIULn2YCC0CeeztrpnmVolGxO
# QGl/3AhTtlRT3pPGnnsRbilGrNpkqD8hcHcUrt7fxTj+fIjTpgO9QANjMCemioNK
# GBjrjMG7FZqG+3BCVz9Yg19T6N3vlh5B9Nuk6UgKDIx8l6ykgx6ja/WOfDQiDt8z
# giHAkkk6a9DTXTQUiM15cdaxbHtt5VfVjuYU8DfIEuG0YvoIuueIBE/1X+Eql3nL
# UDF+CNh4W2ACc7UNIOeWz6ujpaiVyrUd/7o0nJnbbANAfdPlzFWEr65fhb9K4Vn8
# BXWHesUX6QvIN3TPfbhEGgnVGyZkPTTrKb++dtR76LBYESinqtp634ppyZ57eRSQ
# 8O1sLwPIUtJPWM5yWSbHfXwSVUkn7E1TFgQ1ROZ0wWK0u2+HU+KXm5WmFi03gDPj
# p+RIu7db1rmkvbxT2xiTM/M7Gx8vXPKtgGtApx9iRBVslPvXdhWl8UOhggMgMIID
# HAYJKoZIhvcNAQkGMYIDDTCCAwkCAQEwdzBjMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQg
# UlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBAhAMTWlyS5T6PCpKPSkHgD1a
# MA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkq
# hkiG9w0BCQUxDxcNMjIxMjExMTgyNDM0WjAvBgkqhkiG9w0BCQQxIgQgksM+FC74
# XI+4Rtz6e16h2iT3nNS2EH6CXzmUl3y5/FQwDQYJKoZIhvcNAQEBBQAEggIABZy6
# wLDbWnUxM1YuGYjppD+C+FwEG9Ep+TWtyy6KmbtM4CO085K47GVb0aeT7Y93ql6e
# NVq7SinORJLbujeD7mH/hu7gCc2Mf1qeS3TgN/YRm9jx8JzJxWZdCsPgFT588Wa9
# lnIHrKYwFEjfRAQ6pS9fGvUWmDoIrvwBnj5O6zJn2NeQkzqGqht9IY0W4l/rONS+
# 2reDhqp66WuGXC63QOmhOzygcjfirhhV7wlexX0jJ3W35KTLurRJfCP1Eq0rYYKN
# QayxY9GJafowMaGrDMxhs7ukZisJpk519iXqdPFIgLQZAMV3Ic1c/IM6CcFP2i58
# hdt7POUiHtisHT1o7paNuSh6goCLUxKToFxKaA0+3T/3ooA8KPi3tOkvqWi5lVUX
# leWfv3L8t0j7e21SXRvgIArpE0/TTzDLFfI8LPvlZLH/gNPIv2+kRvPQtJosKjGj
# BF+sRWBqTezN5cM5GexPivMhoHpXdX8+R7FjIOQ+fF+UbNjLYPsd7G2gLhot/dcP
# +7uExl78p2z//66G5PZIK5eN3JJiNdWFbU21h16C7bLfDqFkq3qSllWkEv1lpcQ7
# 9FGuVqu7ZVw9/XzMlaFVGjGtHBiNBiPaMTm2acJVVRpI1CGZUmfr8z2p/GxalCxi
# 2ehxsuaYN43hsA3GnVs/YNThhNVSR2Sob6CqC7M=
# SIG # End signature block
