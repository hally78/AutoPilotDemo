
$location = "westeurope"
$RGName = "Templates-RG"
$sAccountName = "gabim101templates"
$containerName = "images"

New-AzResourceGroup -Name $RGName -Location $location

$context = New-AzStorageAccount -ResourceGroupName $RGName -name $sAccountName -Location $location -skuname Standard_LRS

New-AzStorageContainer -name $containerName -Context $context.Context -Permission blob