

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module Subnet -Force
install-Module Microsoft.Graph.Intune -Force
install-Module WindowsAutopilotIntune -Forceorce
