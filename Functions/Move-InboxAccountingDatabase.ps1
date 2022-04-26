Function Move-InboxAccountingDatabase {

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
    https://directaccess.richardhicks.com/2022/03/21/inbox-accounting-database-management/

.LINK
    https://github.com/richardhicks/InboxAccountingDatabaseManagement/

.NOTES
    Version:        1.01
    Creation Date:  March 19, 2022
    Last Updated:   March 19, 2022
    Author:         Richard Hicks
    Organization:   Richard M. Hicks Consulting, Inc.
    Contact:        rich@richardhicks.com
    Web Site:       https://www.richardhicks.com/

#>

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

                Get-Service RaMgmtSvc -ErrorAction Stop | Stop-Service -Force -ErrorAction Stop

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

                Get-Service RaMgmtSvc -ErrorAction stop | Start-Service -ErrorAction stop

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
# MIIhjgYJKoZIhvcNAQcCoIIhfzCCIXsCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUeoZZHjIozEDh97SI4k2uGGJV
# JRygghs2MIIGrjCCBJagAwIBAgIQBzY3tyRUfNhHrP0oZipeWzANBgkqhkiG9w0B
# AQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVk
# IFJvb3QgRzQwHhcNMjIwMzIzMDAwMDAwWhcNMzcwMzIyMjM1OTU5WjBjMQswCQYD
# VQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lD
# ZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAxoY1BkmzwT1ySVFVxyUDxPKR
# N6mXUaHW0oPRnkyibaCwzIP5WvYRoUQVQl+kiPNo+n3znIkLf50fng8zH1ATCyZz
# lm34V6gCff1DtITaEfFzsbPuK4CEiiIY3+vaPcQXf6sZKz5C3GeO6lE98NZW1Oco
# LevTsbV15x8GZY2UKdPZ7Gnf2ZCHRgB720RBidx8ald68Dd5n12sy+iEZLRS8nZH
# 92GDGd1ftFQLIWhuNyG7QKxfst5Kfc71ORJn7w6lY2zkpsUdzTYNXNXmG6jBZHRA
# p8ByxbpOH7G1WE15/tePc5OsLDnipUjW8LAxE6lXKZYnLvWHpo9OdhVVJnCYJn+g
# GkcgQ+NDY4B7dW4nJZCYOjgRs/b2nuY7W+yB3iIU2YIqx5K/oN7jPqJz+ucfWmyU
# 8lKVEStYdEAoq3NDzt9KoRxrOMUp88qqlnNCaJ+2RrOdOqPVA+C/8KI8ykLcGEh/
# FDTP0kyr75s9/g64ZCr6dSgkQe1CvwWcZklSUPRR8zZJTYsg0ixXNXkrqPNFYLwj
# jVj33GHek/45wPmyMKVM1+mYSlg+0wOI/rOP015LdhJRk8mMDDtbiiKowSYI+RQQ
# EgN9XyO7ZONj4KbhPvbCdLI/Hgl27KtdRnXiYKNYCQEoAA6EVO7O6V3IXjASvUae
# tdN2udIOa5kM0jO0zbECAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAw
# HQYDVR0OBBYEFLoW2W1NhS9zKXaaL3WMaiCPnshvMB8GA1UdIwQYMBaAFOzX44LS
# cV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEF
# BQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRp
# Z2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYy
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5j
# cmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEB
# CwUAA4ICAQB9WY7Ak7ZvmKlEIgF+ZtbYIULhsBguEE0TzzBTzr8Y+8dQXeJLKftw
# ig2qKWn8acHPHQfpPmDI2AvlXFvXbYf6hCAlNDFnzbYSlm/EUExiHQwIgqgWvalW
# zxVzjQEiJc6VaT9Hd/tydBTX/6tPiix6q4XNQ1/tYLaqT5Fmniye4Iqs5f2MvGQm
# h2ySvZ180HAKfO+ovHVPulr3qRCyXen/KFSJ8NWKcXZl2szwcqMj+sAngkSumScb
# qyQeJsG33irr9p6xeZmBo1aGqwpFyd/EjaDnmPv7pp1yr8THwcFqcdnGE4AJxLaf
# zYeHJLtPo0m5d2aR8XKc6UsCUqc3fpNTrDsdCEkPlM05et3/JWOZJyw9P2un8WbD
# Qc1PtkCbISFA0LcTJM3cHXg65J6t5TRxktcma+Q4c6umAU+9Pzt4rUyt+8SVe+0K
# XzM5h0F4ejjpnOHdI/0dKNPH+ejxmF/7K9h+8kaddSweJywm228Vex4Ziza4k9Tm
# 8heZWcpw8De/mADfIBZPJ/tgZxahZrrdVcA6KYawmKAr7ZVBtzrVFZgxtGIJDwq9
# gdkT/r+k0fNX2bwE+oLeMt8EifAAzV3C+dAjfwAL5HYCJtnwZXZCpimHCUcr5n8a
# pIUP/JiW9lVUKx+A+sDyDivl1vupL0QVSucTDh3bNzgaoSv27dZ8/DCCBrAwggSY
# oAMCAQICEAitQLJg0pxMn17Nqb2TrtkwDQYJKoZIhvcNAQEMBQAwYjELMAkGA1UE
# BhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2lj
# ZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4XDTIx
# MDQyOTAwMDAwMFoXDTM2MDQyODIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAVBgNV
# BAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0
# IENvZGUgU2lnbmluZyBSU0E0MDk2IFNIQTM4NCAyMDIxIENBMTCCAiIwDQYJKoZI
# hvcNAQEBBQADggIPADCCAgoCggIBANW0L0LQKK14t13VOVkbsYhC9TOM6z2Bl3DF
# u8SFJjCfpI5o2Fz16zQkB+FLT9N4Q/QX1x7a+dLVZxpSTw6hV/yImcGRzIEDPk1w
# JGSzjeIIfTR9TIBXEmtDmpnyxTsf8u/LR1oTpkyzASAl8xDTi7L7CPCK4J0JwGWn
# +piASTWHPVEZ6JAheEUuoZ8s4RjCGszF7pNJcEIyj/vG6hzzZWiRok1MghFIUmje
# EL0UV13oGBNlxX+yT4UsSKRWhDXW+S6cqgAV0Tf+GgaUwnzI6hsy5srC9KejAw50
# pa85tqtgEuPo1rn3MeHcreQYoNjBI0dHs6EPbqOrbZgGgxu3amct0r1EGpIQgY+w
# OwnXx5syWsL/amBUi0nBk+3htFzgb+sm+YzVsvk4EObqzpH1vtP7b5NhNFy8k0Uo
# gzYqZihfsHPOiyYlBrKD1Fz2FRlM7WLgXjPy6OjsCqewAyuRsjZ5vvetCB51pmXM
# u+NIUPN3kRr+21CiRshhWJj1fAIWPIMorTmG7NS3DVPQ+EfmdTCN7DCTdhSmW0td
# dGFNPxKRdt6/WMtyEClB8NXFbSZ2aBFBE1ia3CYrAfSJTVnbeM+BSj5AR1/JgVBz
# hRAjIVlgimRUwcwhGug4GXxmHM14OEUwmU//Y09Mu6oNCFNBfFg9R7P6tuyMMgkC
# zGw8DFYRAgMBAAGjggFZMIIBVTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQW
# BBRoN+Drtjv4XxGG+/5hewiIZfROQjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/
# 57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMwdwYI
# KwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5j
# b20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdp
# Q2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9j
# cmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMBwGA1Ud
# IAQVMBMwBwYFZ4EMAQMwCAYGZ4EMAQQBMA0GCSqGSIb3DQEBDAUAA4ICAQA6I0Q9
# jQh27o+8OpnTVuACGqX4SDTzLLbmdGb3lHKxAMqvbDAnExKekESfS/2eo3wm1Te8
# Ol1IbZXVP0n0J7sWgUVQ/Zy9toXgdn43ccsi91qqkM/1k2rj6yDR1VB5iJqKisG2
# vaFIGH7c2IAaERkYzWGZgVb2yeN258TkG19D+D6U/3Y5PZ7Umc9K3SjrXyahlVhI
# 1Rr+1yc//ZDRdobdHLBgXPMNqO7giaG9OeE4Ttpuuzad++UhU1rDyulq8aI+20O4
# M8hPOBSSmfXdzlRt2V0CFB9AM3wD4pWywiF1c1LLRtjENByipUuNzW92NyyFPxrO
# JukYvpAHsEN/lYgggnDwzMrv/Sk1XB+JOFX3N4qLCaHLC+kxGv8uGVw5ceG+nKcK
# BtYmZ7eS5k5f3nqsSc8upHSSrds8pJyGH+PBVhsrI/+PteqIe3Br5qC6/To/RabE
# 6BaRUotBwEiES5ZNq0RA443wFSjO7fEYVgcqLxDEDAhkPDOPriiMPMuPiAsNvzv0
# zh57ju+168u38HcT5ucoP6wSrqUvImxB+YJcFWbMbA7KxYbD9iYzDAdLoNMHAmpq
# QDBISzSoUSC7rRuFCOJZDW3KBVAr6kocnqX9oKcfBnTn8tZSkP2vhUgh+Vc7tJwD
# 7YZF9LRhbr9o4iZghurIr6n+lB3nYxs6hlZ4TjCCBsYwggSuoAMCAQICEAp6Soie
# yZlCkAZjOE2Gl50wDQYJKoZIhvcNAQELBQAwYzELMAkGA1UEBhMCVVMxFzAVBgNV
# BAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0
# IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQTAeFw0yMjAzMjkwMDAwMDBa
# Fw0zMzAzMTQyMzU5NTlaMEwxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2Vy
# dCwgSW5jLjEkMCIGA1UEAxMbRGlnaUNlcnQgVGltZXN0YW1wIDIwMjIgLSAyMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAuSqWI6ZcvF/WSfAVghj0M+7M
# XGzj4CUu0jHkPECu+6vE43hdflw26vUljUOjges4Y/k8iGnePNIwUQ0xB7pGbumj
# S0joiUF/DbLW+YTxmD4LvwqEEnFsoWImAdPOw2z9rDt+3Cocqb0wxhbY2rzrsvGD
# 0Z/NCcW5QWpFQiNBWvhg02UsPn5evZan8Pyx9PQoz0J5HzvHkwdoaOVENFJfD1De
# 1FksRHTAMkcZW+KYLo/Qyj//xmfPPJOVToTpdhiYmREUxSsMoDPbTSSF6IKU4S8D
# 7n+FAsmG4dUYFLcERfPgOL2ivXpxmOwV5/0u7NKbAIqsHY07gGj+0FmYJs7g7a5/
# KC7CnuALS8gI0TK7g/ojPNn/0oy790Mj3+fDWgVifnAs5SuyPWPqyK6BIGtDich+
# X7Aa3Rm9n3RBCq+5jgnTdKEvsFR2wZBPlOyGYf/bES+SAzDOMLeLD11Es0MdI1DN
# kdcvnfv8zbHBp8QOxO9APhk6AtQxqWmgSfl14ZvoaORqDI/r5LEhe4ZnWH5/H+gr
# 5BSyFtaBocraMJBr7m91wLA2JrIIO/+9vn9sExjfxm2keUmti39hhwVo99Rw40KV
# 6J67m0uy4rZBPeevpxooya1hsKBBGBlO7UebYZXtPgthWuo+epiSUc0/yUTngIsp
# QnL3ebLdhOon7v59emsCAwEAAaOCAYswggGHMA4GA1UdDwEB/wQEAwIHgDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMCAGA1UdIAQZMBcwCAYG
# Z4EMAQQCMAsGCWCGSAGG/WwHATAfBgNVHSMEGDAWgBS6FtltTYUvcyl2mi91jGog
# j57IbzAdBgNVHQ4EFgQUjWS3iSH+VlhEhGGn6m8cNo/drw0wWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0
# UlNBNDA5NlNIQTI1NlRpbWVTdGFtcGluZ0NBLmNybDCBkAYIKwYBBQUHAQEEgYMw
# gYAwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBYBggrBgEF
# BQcwAoZMaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZEc0UlNBNDA5NlNIQTI1NlRpbWVTdGFtcGluZ0NBLmNydDANBgkqhkiG9w0BAQsF
# AAOCAgEADS0jdKbR9fjqS5k/AeT2DOSvFp3Zs4yXgimcQ28BLas4tXARv4QZiz9d
# 5YZPvpM63io5WjlO2IRZpbwbmKrobO/RSGkZOFvPiTkdcHDZTt8jImzV3/ZZy6HC
# 6kx2yqHcoSuWuJtVqRprfdH1AglPgtalc4jEmIDf7kmVt7PMxafuDuHvHjiKn+8R
# yTFKWLbfOHzL+lz35FO/bgp8ftfemNUpZYkPopzAZfQBImXH6l50pls1klB89Bem
# h2RPPkaJFmMga8vye9A140pwSKm25x1gvQQiFSVwBnKpRDtpRxHT7unHoD5PELkw
# NuTzqmkJqIt+ZKJllBH7bjLx9bs4rc3AkxHVMnhKSzcqTPNc3LaFwLtwMFV41pj+
# VG1/calIGnjdRncuG3rAM4r4SiiMEqhzzy350yPynhngDZQooOvbGlGglYKOKGuk
# zp123qlzqkhqWUOuX+r4DwZCnd8GaJb+KqB0W2Nm3mssuHiqTXBt8CzxBxV+NbTm
# tQyimaXXFWs1DoXW4CzM4AwkuHxSCx6ZfO/IyMWMWGmvqz3hz8x9Fa4Uv4px38qX
# sdhH6hyF4EVOEhwUKVjMb9N/y77BDkpvIJyu2XMyWQjnLZKhGhH+MpimXSuX4IvT
# nMxttQ2uR2M4RxdbbxPaahBuH0m3RFu0CAqHWlkEdhGhp3cCExwwggcCMIIE6qAD
# AgECAhABZnISBJVCuLLqeeLTB6xEMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYT
# AlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQg
# VHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcgUlNBNDA5NiBTSEEzODQgMjAyMSBDQTEw
# HhcNMjExMjAyMDAwMDAwWhcNMjQxMjIwMjM1OTU5WjCBhjELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCkNhbGlmb3JuaWExFjAUBgNVBAcTDU1pc3Npb24gVmllam8xJDAi
# BgNVBAoTG1JpY2hhcmQgTS4gSGlja3MgQ29uc3VsdGluZzEkMCIGA1UEAxMbUmlj
# aGFyZCBNLiBIaWNrcyBDb25zdWx0aW5nMIIBojANBgkqhkiG9w0BAQEFAAOCAY8A
# MIIBigKCAYEA6svrVqBRBbazEkrmhtz7h05LEBIHp8fGlV19nY2gpBLnkDR8Mz/E
# 9i1cu0sdjieC4D4/WtI4/NeiR5idtBgtdek5eieRjPcn8g9Zpl89KIl8NNy1UlOW
# NV70jzzqZ2CYiP/P5YGZwPy8Lx5rIAOYTJM6EFDBvZNti7aRizE7lqVXBDNzyeHh
# fXYPBxaQV2It+sWqK0saTj0oNA2Iu9qSYaFQLFH45VpletKp7ded2FFJv2PKmYrz
# Ytax48xzUQq2rRC5BN2/n7771NDfJ0t8udRhUBqTEI5Z1qzMz4RUVfgmGPT+CaE5
# 5NyBnyY6/A2/7KSIsOYOcTgzQhO4jLmjTBZ2kZqLCOaqPbSmq/SutMEGHY1MU7xr
# WUEQinczjUzmbGGw7V87XI9sn8EcWX71PEvI2Gtr1TJfnT9betXDJnt21mukioLs
# UUpdlRmMbn23or/VHzE6Nv7Kzx+tA1sBdWdC3Mkzaw/Mm3X8Wc7ythtXGBcLmBag
# pMGCCUOk6OJZAgMBAAGjggIGMIICAjAfBgNVHSMEGDAWgBRoN+Drtjv4XxGG+/5h
# ewiIZfROQjAdBgNVHQ4EFgQUxF7do+eIG9wnEUVjckZ9MsbZ+4kwDgYDVR0PAQH/
# BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8Ega0wgaowU6BRoE+G
# TWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNENvZGVT
# aWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBPhk1odHRwOi8vY3Js
# NC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2RlU2lnbmluZ1JTQTQw
# OTZTSEEzODQyMDIxQ0ExLmNybDA+BgNVHSAENzA1MDMGBmeBDAEEATApMCcGCCsG
# AQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMwgZQGCCsGAQUFBwEB
# BIGHMIGEMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRy
# dXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3J0MAwGA1Ud
# EwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAEvHt/OKalRysHQdx4CXSOcgoayu
# FXWNwi/VFcFr2EK37Gq71G4AtdVcWNLu+whhYzfCVANBnbTa9vsk515rTM06exz0
# QuMwyg09mo+VxZ8rqOBHz33xZyCoTtw/+D/SQxiO8uQR0Oisfb1MUHPqDQ69FTNq
# IQF/RzC2zzUn5agHFULhby8wbjQfUt2FXCRlFULPzvp7/+JS4QAJnKXq5mYLvopW
# sdkbBn52Kq+ll8efrj1K4iMRhp3a0n2eRLetqKJjOqT335EapydB4AnphH2WMQBH
# Hroh5n/fv37dCCaYaqo9JlFnRIrHU7pHBBEpUGfyecFkcKFwsPiHXE1HqQJCPmMb
# vPdV9ZgtWmuaRD0EQW13JzDyoQdJxQZSXJhDDL+VSFS8SRNPtQFPisZa2IO58d1C
# vf5G8iK1RJHN/Qx413lj2JSS1o3wgNM3Q5ePFYXcQ0iPxjFYlRYPAaDx8t3olg/t
# VK8sSpYqFYF99IRqBNixhkyxAyVCk6uLBLgwE9egJg1AFoHEdAeabGgT2C0hOyz5
# 5PNoDZutZB67G+WN8kGtFYULBloRKHJJiFn42bvXfa0Jg1jZ41AAsMc5LUNlqLhI
# j/RFLinDH9l4Yb0ddD4wQVsIFDVlJgDPXA9E1Sn8VKrWE4I0sX4xXUFgjfuVfdcN
# k9Q+4sJJ1YHYGmwLMYIFwjCCBb4CAQEwfTBpMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQg
# Q29kZSBTaWduaW5nIFJTQTQwOTYgU0hBMzg0IDIwMjEgQ0ExAhABZnISBJVCuLLq
# eeLTB6xEMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkG
# CSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
# AYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRtd8uCSNRVnIC+h3JU0ywIsRWjSjANBgkq
# hkiG9w0BAQEFAASCAYCSYWrijWpbxl4bGOtubb5PmK9YP3rtKN4jlsxfXCU/dSEh
# uNEXbn6kBw7ye8t2QjfZNMF9542pdjgKgiUFDK2VpGCWakUDLb1WYvdmbMCgfhTK
# 25TPxjCRarw44GOBCyTfpjNZbv/CnZthLIqfp8qQWG2JnQ3Za3s/uViMgzTtliPU
# jBlhHOQTWlWwT40NH0jzMHxb0FL15vzHZIHoT7tmAVV6y4Je1Xl4I+xtGzWUz+wl
# rFBvkvMUk5v9gY9k+blEdQumkzsZNIOsS9dMMV3EAA2OV03lgj1yIkgGLXt/+d/a
# iqecXQuCYBgIPyCTPARN7KY+7S1gWj2IQR6wF4QwMHWZsmqvFjTHQCbwEvBP3Sns
# Nj3fEbAdKFk+Egsg5WSYOHVlfO3/ErXiiBF6OPkfpxHVGSZjC6bqQ/t0lUA9nZ9R
# l5kPiX2ZSUo2miRT0mFV7v38hRk8NtMK05I/MDBa+nWXwQDYJK3+xoJ2FXU5W8o4
# 3fwF5PUcdCKPtluV/5KhggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCCAwkCAQEwdzBj
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMT
# MkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5n
# IENBAhAKekqInsmZQpAGYzhNhpedMA0GCWCGSAFlAwQCAQUAoGkwGAYJKoZIhvcN
# AQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjIwNDI1MjIwNDIyWjAv
# BgkqhkiG9w0BCQQxIgQgtGSKq9r56OXrUrha3sGKpvs6m1c3Yf0o/kNlXKTWmLEw
# DQYJKoZIhvcNAQEBBQAEggIADWArJyLU149bjEXUagIcoHeX5y7wChPIqglrjPOi
# sDPUhNDiTEKe9gcIriAWPCHHQDKrzz7jWIzk6gODUy3Pm2g9TMP4oF0b0OFA6GQd
# 2MQ0O/5VuWeP25UH/Mq+KzBr+EnlEay8n2/2xrHnQzWvh39/BSevMbjEhdvo7qLi
# 7KwjyuoEdt3EhoAcet0JU4J8z18Z0gSGjkbBwKXDK+tcoCAWCkYP1DPtnlDCewDf
# uGzhzTb+/FJYc+7KDDeMkIKBy2ca0nNTEvoL9jwxsNV/eAf0TmY6CVIF9TSkLIch
# tsmbJrFgLSUW5rscTM9D+2A1+WBH7qtxRVvoO+xqPuMBWm8qY8CPY5gusAyLQG5R
# xICVw1pgpCzyUm3ry8/Y+b3RwNASuFiHwnwiSigiW8zuCYfVIprepx7yhNSfZz5N
# fgJptIXrtdhJ/W4KQ2WMXniydFlfbjoiGr2FwmjFQLRYk8R+LP2hWSPjYmWfcmza
# aTo2+gBzm/lQwblxNMqtOJgzW2BsUmXOUtDhQh5J4duV1N6PsB/dMcB/dJWkOsYE
# D8eF0DrBBvPgYL162qF+KgLOgFFq+n/4SOIiRivXa0dDaVr/+8/v0klqoYbhpDXd
# JjWsPaPVsoCd4LrwxqtX3Y53nA6e/UCgWqWyr5PzsNJnNu+mKbQDnuE2NfstJJ97
# fEc=
# SIG # End signature block
