<#
    ReferenceFile
    by Dan Felman/HP Inc

    Script will parse an HPIA reference file and provides a means to remove or replace a Softpaq 
    solution with a superseded version

    The working reference file is updated as changes are made to the Solutions selections. This
    working file is to be used with HPIA /ReferenceFile:<file.xml> runtime option

param(
    [Parameter( Mandatory = $false )]$CacheDir,     # for future use    
    [Parameter( Mandatory = $false )]$ReferenceFile # for future use    
) # param
#>
$ReFileVersion = '1.01.16'
'ReferenceFile.ps1 - '+$ReFileVersion+' (Jul-17-2023)'
###################################################################################
$Script:OSs = @('10','11')      # what shows on the GUI entry box
$Script:OS10Vers = @('2009','21H1','21H2','22H2')
$Script:OS11Vers = @('21H2','22H2')
###################################################################################
$Script:OS
$Script:OSVer

$Script:RefFilePath = $null         # working reference file path
$Script:DebugInfo = $true

# check for CMSL - required to run this script
Try {
    $Error.Clear()
    Get-HPDeviceDetails -ErrorAction SilentlyContinue > $null
} Catch {
    $error[0].exception          # $error[0].exception.gettype().fullname 
    return
}
# Set up the Cache folder path that hosts the downloaded/unpacked reference file
if ( $Script:CacheDir -eq $null ) { 
    $Script:CacheDir = $Pwd.Path 
}
$Script:CacheDir = (Convert-Path $Script:CacheDir)
$Script:LogFilePath = $Script:CacheDir+'\ReferenceFile.log'

<#################################################################################
   Function Get_FileFromHP
   1) retrieves latest reference file from HP, saves to cache folder
      (with CMSL Get-SofptaqList)
   2) finds downloaded reference (xml) file
   3) copies file from cache folder to current folder
      replacing file if same file name exists in folder

   Returns: path of reference file in current folder
#################################################################################>
Function Get_FileFromHP {
    [CmdletBinding()] param( $pPlatform, $pOS, $pOSVer ) 

    if ( $Script:DebugInfo ) { ">> Get_FileFromHP() - platform: $pPlatform - OS $pOS/$pOSVer" | out-file -append $Script:LogFilePath }
    $gr_CacheDir = (Convert-Path $Pwd.Path)
    $gr_Path = $null
    # let's download a reference file and create a copy to work on
    Try {
        $Error.Clear()
        get-softpaqList -platform $pPlatform -OS $pOS -OSVer $pOSVer -Overwrite 'Yes' -CacheDir $gr_CacheDir -EA SilentlyContinue | Out-Null
        # find the downloaded Reference_File.xml file
        $gr_XmlFile = Get-Childitem -Path $gr_CacheDir'\cache' -Include "*.xml" -Recurse -File |
            where { ($_.Directory -match '.dir') -and ($_.Name -match $pPlatform) `
                -and ($_.Name -match $pOS.Substring(3)) -and ($_.Name -match $pOSVer) }
        Copy-Item $gr_XmlFile -Destination $Pwd.Path -Force # make a copy to the working directory (where the script runs from)
        # and return the path to the XML file in the working folder
        $gr_Path = "$($Pwd.Path)\$($gr_XmlFile.Name)" # final destination in current folder
    } Catch {
        write-host 'Reference File failure' -ForegroundColor yellow
        write-host $error[0].exception              # $error[0].exception.gettype().fullname 
    }
    if ( $Script:DebugInfo ) { "<< Get_FileFromHP() - Downloaded file for: $pPlatform/$pOS/$pOSVer" | out-file -append $Script:LogFilePath }
    if ( $Script:DebugInfo ) { "<< Get_FileFromHP() - Using: $gr_Path" | out-file -append $Script:LogFilePath }

    return $gr_Path   # final destination, if found

} # Function Get_FileFromHP

<#################################################################################
    Function Get_LocalFile

   1) copy reference file argument to the caching folde
   2) if file with same reference file name exists in 
      current folder, renames it as .bak (only once)
   3) copies file from cache folder to current folder

   Returns: path of reference file in current folder
#################################################################################>

Function Get_LocalFile {
    [CmdletBinding()] param( $pReferenceFile ) 
    if ( $Script:DebugInfo ) { ">> Get_LocalFile() - reference: $pReferenceFile" | out-file -append $Script:LogFilePath }
    $gr_FileReturn = $null
    if ( Test-Path $pReferenceFile ) {
        $gr_RefFileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($pReferenceFile)
        $gr_RefFilePath = Split-Path -Path $pReferenceFile -Parent 
        $gr_RefFileBakFullPath = $gr_RefFilePath+'\'+$gr_RefFileNameNoExt+'.bak'
        # make a backup of reference file from arg to a .bak version
        Copy-Item -Path $pReferenceFile -Destination $gr_RefFileBakFullPath -Force
        $gr_FileReturn = $pReferenceFile
    } else {
        '-- Reference File does not exist'
        return $gr_FileReturn
    } # else if ( Test-Path $pReferenceFile )

    if ( $Script:DebugInfo ) { "<< Get_LocalFile() - Using: $pReferenceFile" | out-file -append $Script:LogFilePath }
    return $gr_FileReturn

} # Function Get_LocalFile


<######################################################################################
    Function Get_UWPInfo
        This functions determines if the Softpaq has a UWP requirement and if it is installed
    Parms: $pCVAMetadata:       content of all CVA metadata file
           $pInstalledAppxName:     registry list of UWP/appx installed in system
    Returns: the Softpaq UWP name and version, and (if) installed the UWP version
            [0] UWP full name - from reference file store info section (or $null)
            [1] UWP version - from reference file store info section (or $null)
            [2] UWP version - from installed UWP store info section (or $null)
#>#####################################################################################
Function Get_UWPInfo {
    [CmdletBinding()] param( $pCVAMetadata, $pInstalledAppxName ) 

    if ( $Script:DebugInfo ) { ">> Get_UWPInfo() - app name to find: $pInstalledAppxName" | out-file -append $Script:LogFilePath }

    $gu_SoftpaqID = $pCVAMetadata.Softpaq.SoftpaqNumber
    $gu_CVAUWPFullName = $null
    $gu_CVAUWPName = $null
    $gu_CVAUWPVersion = $null

    if ( $pCVAMetadata.Private.MS_Store_App -eq 1 ) {
        # find the UWP package info from the CVA file
        [array]$gu_UWPPackageList = $pCVAMetadata.'Store Package Info'.Values
        foreach ( $iPkgFullName in $gu_UWPPackageList ) {
            $gu_UWPPackageHash = $iPkgFullName.split('_')
            if ( $gu_UWPPackageHash[0] -eq $pInstalledAppxName ) {
                $gu_CVAUWPFullName = $iPkgFullName
                $gu_CVAUWPName = $gu_UWPPackageHash[0]          # ex. NVIDIAControlPanel
                $gu_CVAUWPVersion = $gu_UWPPackageHash[1]       # ex. 8.1.962.0
                break               
            } # if ( $gu_UWPPackageHash[0] -eq $pInstalledAppxName )
        } # foreach ( $iPkgFullName in $gu_UWPPackageList )
    } # if ( $pCVAMetadata.Private.MS_Store_App -eq 1 )

    if ( $Script:DebugInfo ) {
        if ( $gu_CVAUWPVersion ) {           
            " Get_UWPInfo() Softpaq: $($gu_SoftpaqID)" | out-file -append $Script:LogFilePath
            "    ... [0] App Full Name: $($gu_CVAUWPFullName)" | out-file -append $Script:LogFilePath
            "    ... [1] Version: $($gu_CVAUWPVersion)" | out-file -append $Script:LogFilePath
        } else {
            "  < Get_UWPInfo() Softpaq: $($gu_SoftpaqID) - NO UWP found" | out-file -append $Script:LogFilePath
        }
    } # if ( $Script:DebugInfo )

    return $gu_CVAUWPFullName, $gu_CVAUWPVersion
} # Function Get_UWPInfo

<#################################################################################
    Function Show_SoftpaqList
    find and display entries from the reference file in form textbox
    returns number of listed Softpaqs
    Args: $pFormList    # GUI TextBox list to display Solutions
        $pXMLSolutions  # node list from XML reference file
        $pCategories    # list of categories to match when showing Solutions
                        # ... currently using simple 'match' of categories
        $pNameMatch     # name of Softpaq to match for listing
    Return: Number of Solutions displayed
#################################################################################>  
Function Show_SoftpaqList {
    [CmdletBinding()] param( $pFormList, $pXMLSolutions, $pCategories, $pNameMatch )

    $pFormList.Items.Clear()
    $ss_count = 0
    foreach ( $iSoftpaq in $pXMLSolutions ) {     # loop thru every Solution (Softpaq)
        foreach ( $iCat in $pCategories ) {       # check for the Sofptaq category being selected   
            if ( $iSoftpaq.category -match $iCat ) {  
                if ( $null -eq $pNameMatch ) {
                    $ss_TmpEntry = "$($iSoftpaq.id) $($iSoftpaq.name) / $($iSoftpaq.version) / $($iSoftpaq.DateReleased)"
                    [void]$pFormList.items.add($ss_TmpEntry)   
                    $ss_count += 1                 
                } elseif ( $iSoftpaq.name -match $pNameMatch ) {
                    $ss_TmpEntry = "$($iSoftpaq.id) $($iSoftpaq.name) / $($iSoftpaq.version) / $($iSoftpaq.DateReleased)"
                    [void]$pFormList.items.add($ss_TmpEntry)
                    $ss_count += 1    
                }                
                break
            } # if ( $iSoftpaq.category -match $iCat )
        } # foreach ( $iCat in $pCategories )
    } # foreach ( $iSoftpaq in $ss_XMLSolutions ) { 
    return $ss_count

} # Function Show_SoftpaqList

<#################################################################################
    Function List_Supersedes
    shows superseded entries in form superseded textbox
    Obtains the lists directly from the XML reference file
    Args: $pssFormList      # GUI TextBox to display SUperseded Solutions for selected Solution
        $pSoftpaqID         # Softpaq ID to match
    Returns: no return
#################################################################################>  
Function List_Supersedes {
    [CmdletBinding()] param( $pssFormList, $pSoftpaqID ) 

    $pssFormList.Items.Clear()

    $la_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
    $ls_ssXMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions-Superseded/UpdateInfo")
    # find the selected Softpaq node in /Solutions
    $ls_Node = $la_XMLSolutions | where { $_.id -eq $pSoftpaqID }  
    # now, search for more entries in the SS chain
    while ( $null -ne $ls_Node.Supersedes ) {        
        $ls_Node = $ls_ssXMLSolutions | where { $_.id -eq $ls_Node.Supersedes }
        $ls_TmpEntry = "$($ls_Node.id) $($ls_Node.name) / $($ls_Node.version) / $($ls_Node.DateReleased)"
        [void]$pssFormList.items.add($ls_TmpEntry)
    } # while ( $null -ne $ls_Node.Supersedes)

} # Function List_Supersedes

<#################################################################################
    Function Remove_XMLUWPApps
    Handle specifics of removing a UWP entry from the reference file... 
    Called by a Driver or Software Softpaq removal function
    Args: $pSolutionNode            # the Software solution to use for UWP search
    Return: # of UWP entries removed
#################################################################################> 
Function Remove_XMLUWPApps {
    [CmdletBinding()] param( $pSolutionNode )

    if ( $Script:DebugInfo ) { ">> Remove_XMLUWPApps() - Solution: $($pSolutionNode.Name)" | out-file -append $Script:LogFilePath }
    $rx_RemovedUWPCount = 0

    $rx_XMLUWPInstalled = $Script:xmlContent.SelectNodes("ImagePal/SystemInfo/UWPApps/UWPApp")
    $rx_UWPNode = $rx_XMLUWPInstalled | Where-Object { $_.Solutions.UpdateInfo.IdRef -eq $pSolutionNode.Id }
    foreach ( $i_UWPNode in [array]$rx_UWPNode ) {
        $rx_UWPFullName = $i_UWPNode.Name
        $i_UWPNode.ParentNode.RemoveChild($i_UWPNode) | Out-Null 
        if ( $Script:DebugInfo ) { ".. Remove_XMLUWPApps() removed UWP: $rx_UWPFullName" | out-file -append $Script:LogFilePath }
        $rx_RemovedUWPCount += 1
    }
    if ( $Script:DebugInfo ) {  ">> Remove_XMLUWPApps() - removed: $rx_RemovedUWPCount" | out-file -append $Script:LogFilePath }

    return $rx_RemovedUWPCount
} # Function Remove_XMLUWPApps

<#################################################################################
    Function Remove_XMLDevices
    Handle specifics of removing devices entries from reference file
    Called by other functions
    Args: $pSolutionNode            # the Dock solution to replace in file
    Return: # of Device entries removed
#################################################################################> 
Function Remove_XMLDevices {
    [CmdletBinding()] param( $pSolutionNode )

    if ( $Script:DebugInfo ) { ">> Remove_XMLDevices() - Solution: $($pSolutionNode.Name)" | out-file -append $Script:LogFilePath }
    $rx_RemovedCount = 0
    $rx_XMLDevices = $Script:xmlContent.SelectNodes("ImagePal/Devices/Device")
    $rx_DevNodes = $rx_XMLDevices | Where-Object { $_.Solutions.UpdateInfo.IdRef -eq $pSolutionNode.Id }
    foreach ( $i_DevNode in [array]$rx_DevNodes ) {
        $rx_DevIDRemoved = $i_DevNode.DeviceID
        $i_DevNode.ParentNode.RemoveChild($i_DevNode) | Out-Null 
        if ( $Script:DebugInfo ) { ".. Remove_XMLDevices() removed Dev entry: $rx_DevIDRemoved" | out-file -append $Script:LogFilePath }
        $rx_RemovedCount += 1
    }
    if ( $Script:DebugInfo ) { "<< Remove_XMLDevices() - removed: $rx_RemovedCount" | out-file -append $Script:LogFilePath }
    return $rx_RemovedCount
} # Function Remove_XMLDevices

<#################################################################################
    Function Remove_XMLSoftwareInstalled
    Handle specifics of removing a category Software softpaq, which may have 
    entries in InstalledSoftware, UWP, and Devices sections of the ref file
    Args: $pSolutionNode            # the Software solution to replace in file
    Return: $true if update occurred
#################################################################################> 
Function Remove_XMLSoftwareInstalled {
    [CmdletBinding()] param( $pSolutionNode )

    if ( $Script:DebugInfo ) { ">> Remove_XMLSoftwareInstalled() - Solution: $($pSolutionNode.Name)" | out-file -append $Script:LogFilePath }
    $rx_RemovedSoftwareInstalled = $false

    # remove entries from SoftwareInstalled area
    $rx_XMLSoftwareInstalled = $Script:xmlContent.SelectNodes("ImagePal/SystemInfo/SoftwareInstalled/Software")
    $rx_SWNode = $rx_XMLSoftwareInstalled | Where-Object { $_.Solutions.UpdateInfo.IdRef -eq $pSolutionNode.Id }
    if ( $rx_SWNode ) {
        $rx_SWInstalled = $rx_SWNode.Name
        $rx_SWNode.ParentNode.RemoveChild($rx_SWNode) | Out-Null  
        if ( $Script:DebugInfo ) { ".. << Remove_XMLSoftwareInstalled() removed: $rx_SWInstalled" | out-file -append $Script:LogFilePath }
        $rx_RemovedSoftwareInstalled = $true 
    }
    
    return $rx_RemovedSoftwareInstalled
} # Function Remove_XMLSoftwareInstalled

<#################################################################################
    Function Update_XMLDevices
    Searches all /Devices nodes in reference file and replaces the solution ID with a
    replacement solution ID, and also updates the driver date and version of the node
    Args: $pSolutionNode        # XML Solution node to replace in /Devices
        $pssSolutionNode        # XML node to replace with
    Returns: no return
#################################################################################>  
Function Update_XMLDevices {
    [CmdletBinding()] param( $pSolutionNode, $pssSolutionNode )

    if ( $Script:DebugInfo ) { ">> Update_XMLDevices() - Solution: $($pSolutionNode.Name) with $($pssSolutionNode.Name)" | out-file -append $Script:LogFilePath }
    $ux_UpdatedDeviceCount = 0
    $ux_XMLDevices = $Script:xmlContent.SelectNodes("ImagePal/Devices/Device")

    foreach ( $i_DevNode in $ux_XMLDevices ) {
        if ( $i_DevNode.Solutions.UpdateInfo.IDRef -eq $pSolutionNode.Id ) {
            $i_DevNode.Solutions.UpdateInfo.IDRef = $pssSolutionNode.id
            $i_DevNode.DriverVersion = $pssSolutionNode.Version
            # compute Devices format of Date (backwards from Softpaq ReleaseDate)
            # NOTE: use Softpaq Release Date, since is all we have in reference file
            # NOTE: use Softpaq Release Date, since is all we have in reference file
            $ux_ssDate = $pssSolutionNode.DateReleased.split('-')                # 2023-03-13 - /Solutions  
            $i_DevNode.DriverDate = $ux_ssDate[1]+'/'+$ux_ssDate[2]+'/'+$ux_ssDate[0] # 03/28/2023 - /Devices
            if ( $Script:DebugInfo ) { ".. Update_XMLDevices() updated DevID: $($i_DevNode.DeviceID)" | out-file -append $Script:LogFilePath }
            $ux_UpdatedDeviceCount += 1
        } # if ( $rx_DevSolution -eq $pSolutionNode.Id )
    } # foreach ( $iDev in $ux_XMLDevices )

    return $ux_UpdatedDeviceCount
} # Function Update_XMLDevices

<#################################################################################
    Function Update_XMLSoftwareInstalled
    Searches node in reference file and replaces the solution ID with a
    replacement solution ID, and also updates the driver date and version of the node
    Args: $pSolutionNode        # XML Solution node to replace in /Devices
        $pssSolutionNode        # XML node to replace with
    Returns: $true if update happened
#################################################################################> 
Function Update_XMLSoftwareInstalled {
    [CmdletBinding()] param( $pSolutionNode, $pssSolutionNode )

    if ( $Script:DebugInfo ) { ">> Update_XMLSoftwareInstalled() - Solution: $($pSolutionNode.Name) with $($pssSolutionNode.Name)" | out-file -append $Script:LogFilePath }
    $ux_UpdatedSoftwareInstalled = $false

    # Check for the SoftwareInstalled area of the Reference File
    $ux_XMLSoftwareInstalled = $Script:xmlContent.SelectNodes("ImagePal/SystemInfo/SoftwareInstalled/Software")
    $ux_SWNode = $ux_XMLSoftwareInstalled | Where-Object { $_.Solutions.UpdateInfo.IdRef -eq $pSolutionNode.Id }
    if ( $ux_SWNode ) {
        $ux_SWNode.Solutions.UpdateInfo.IdRef = $pssSolutionNode.Id
        $ux_SWNode.Version = $pssSolutionNode.Version
            # DateReleased 2023-01-09 >> InstalledDate 20230410
        $ux_SWNode.InstalledDate = $pssSolutionNode.DateReleased.Replace('-','')
        $ux_UpdatedSoftwareInstalled = $true
        if ( $Script:DebugInfo ) { ".. << Update_XMLSoftwareInstalled() updated: $($ux_SWNode.Name)" | out-file -append $Script:LogFilePath }
    } # if ( $ux_SWNode )

    return $ux_UpdatedSoftwareInstalled  
} # Update_XMLSoftwareInstalled

<#################################################################################
    Function Update_XMLUWPApp
    This function finds entries in the reference file UWP entry matching a UWP
    app from the CVA file associtated with the replacement Softpaq solution and
    updates the reference file entry with the UWP app info from [Store Package Info]
    Args: $pSolutionNode            # the solution XML node to replace in file
        $pssSolutionNode            # the replacement solution softpaq node
        $pspqMetadata
    Return: count of UWP entries updated
#################################################################################> 
Function Update_XMLUWPApp {
    [CmdletBinding()] param( $pSolutionNode, $pssSolutionNode, $pspqMetadata )

    if ( $Script:DebugInfo ) { ">> Update_XMLUWPApp() - Solution: $($pSolutionNode.Name) with $($pssSolutionNode.Name)" | out-file -append $Script:LogFilePath }
    $ux_UpdateCount = 0

    $ux_XMLUWPInstalled = $Script:xmlContent.SelectNodes("ImagePal/SystemInfo/UWPApps/UWPApp")
    $ux_UWPNode = $ux_XMLUWPInstalled | Where-Object { $_.Solutions.UpdateInfo.IdRef -eq $pSolutionNode.Id }

    foreach ( $i_UWPNode in [array]$ux_UWPNode ) {
        $i_UWPNode.Solutions.UpdateInfo.IdRef = $pssSolutionNode.Id
        # check for the superseded Softpaqs UWP component, by name, to obtain version info
        # return $gu_CVAUWPFullName [0], $gu_CVAUWPVersion [1]
        $ux_ssUWPRet = Get_UWPInfo $pspqMetadata $i_UWPNode.Name
        if ( $ux_ssUWPRet[1] ) {     
            if ( $Script:DebugInfo ) { 
                "Update_XMLUWPApp() UWP found in CVA (full name): $($ux_ssUWPRet[0])" | out-file -append $Script:LogFilePath
                "Update_XMLUWPApp() UWP found in ref file (full name): $($i_UWPNode.FullName)" | out-file -append $Script:LogFilePath
                }
            if ( $i_UWPNode.FullName -match '_x64_' ) {
                # AppUp.IntelGraphicsExperience_1.100.4628.0_x64__8j3eq9eme6ctt         # reference UWPApp file entry
                # AppUp.IntelGraphicsExperience_1.100.4478.0_neutral_~_8j3eq9eme6ctt    # CVA file store entry
                $i_UWPNode.FullName = [string]$ux_ssUWPRet[0].Replace('_neutral_`~_','_x64_')                
            } else {
                $i_UWPNode.FullName = [string]$ux_ssUWPRet[0].replace('_`~_','__')
            }
            $i_UWPNode.Version = $ux_ssUWPRet[1]                # use version from superseded CVA store entry
        } else {
            $i_UWPNode.Version = $pssSolutionNode.Version       # use superseded Softpaq file version
        }        
        $ux_UpdateCount += 1
    }  # foreach ( $i_UWPNode in [array]$ux_UWPNode )

    if ( $Script:DebugInfo ) { "<< Update_XMLUWPApp() update UWP count:$($ux_UpdateCount)" | out-file -append $Script:LogFilePath }

    return $ux_UpdateCount
} # Function Update_XMLUWPApp

<#################################################################################
    Function Remove_Solution
    Here we remove the node for any solution selected in the UI list
    If more than one item is selected, all are removed
    For each category, we separatly remove any items in the reference file that
    point to the solution
    Args: $pFormSolutionsList       # Solutions node list from XML reference file
        $pCategories                # list of categories to display in form
    Return: count of displayed items in Solutions list box
#################################################################################> 
Function Remove_Solution {
    [CmdletBinding()] param( $pFormSolutionsList, $pCategories, $pName2match )

    if ( $Script:DebugInfo ) { ">> Remove_Solution()" | out-file -append $Script:LogFilePath }
    $rs_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")

    # here we will remove any selected node in the Softpaq list
    foreach ( $i_Sol in $pFormSolutionsList.SelectedItems ) {
        # find the selected Softpaq node in /Solutions
        $rs_SoftpaqID = $i_Sol.split(' ')[0]         # get the SoftPaq ID from string
        $rs_Node = $rs_XMLSolutions | Where-Object { $_.id -eq $rs_SoftpaqID }  
        # handle BIOS separate from other categories
        if ( $rs_Node.Category -match 'BIOS' ) {
            $rs_Removed = $false            # do NOT remove BIOS Softpaq entry from /Solutions
        } else {
            $rx_DockCheck = $false
            switch -regex ( $rs_Node.Category ) {
                '^Driver*'  {   
                    $rx_UWPcount = Remove_XMLUWPApps $rs_Node
                    $rx_Devcount = Remove_XMLDevices $rs_Node
                    if ( ($rx_UWPcount -gt 0) -or ($rx_Devcount -gt 0)) { $rs_Removed = $true }
                }
                '^Software*'  { 
                    $rx_SWInstRemoved = Remove_XMLSoftwareInstalled $rs_Node
                    $rx_UWPcount = Remove_XMLUWPApps $rs_Node
                    $rx_Devcount = Remove_XMLDevices $rs_Node
                    if ( $rx_UWPcount -or ($rx_UWPcount -gt 0) -or ($rx_Devcount -gt 0)) { $rs_Removed = $true }
                }
                '^Dock*'  { 
                    $rx_DockCheck = $true
                    $rs_Removed = Remove_XMLDevices $rs_Node    # remove devices entries first
                }
                'firmware*'  { 
                    if ( -not $rx_DockCheck ) {
                        $rs_Removed = Remove_XMLDevices $rs_Node
                    }
                }
            } # switch -regex ( $rs_Node.Category )
            
            $rs_Node.ParentNode.RemoveChild($rs_Node) | Out-Null    # remove the Solutions entry
            $rs_Removed = $true
        } # else if ( $rs_Node.Category -match 'BIOS' )
    } # foreach ( $i_Sol in $pFormSolutionsList.SelectedItems )

    if ( $rs_Removed ) {
        $Script:xmlContent.Save((Convert-Path $Script:RefFilePath))
        $rs_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
        $rs_SpqCount = Show_SoftpaqList $pFormSolutionsList $rs_XMLSolutions $pCategories $pName2match
    }
     if ( $Script:DebugInfo ) { "<< Remove_Solution()" | out-file -append $Script:LogFilePath }
    return $rs_Removed
} # Function Remove_Solution

<#################################################################################
    Function Replace_Solution
    Here we replace a Softpaq solution with a superseded entry
        otherwise, we replace the solution with the replacement in the list
    Args: $pFormSolutionsList       # Solutions node list from XML reference file
        $pSolution                  # solution/Softpaq to remove or replace (if !$null)
        $pssSolution                # solution/Softpaq to replace with (if !$null)
        $pCategories                # list of categories to display in form
    Return: count of displayed items in Solutions list box
#################################################################################> 
Function Replace_Solution {
    [CmdletBinding()] param( $pFormSolutionsList, $pSolution, $pssSolution, $pCategories, $pName2match )

    if ( $Script:DebugInfo ) { ">> Replace_Solution() - Solution: $($pSolution.split(' ')[0]) with $($pssSolution.split(' ')[0])" | out-file -append $Script:LogFilePath }
    $rs_replaced = $false

    $rs_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
    $rs_ssXMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions-Superseded/UpdateInfo")    

    # let's see if this is a replace order (ss arg must !$null)
    if ( $pssSolution.length -gt 0 ) {
        # find the category for the softpaq
        foreach ( $iSolution in $rs_XMLSolutions ) {
            if ( $iSolution.Id -eq $pSolution.split(' ')[0] ) { $rs_SolutionCategory = $iSolution.Category ; break }
        }
        $rs_SolutionID = $pSolution.split(' ')[0]                 # get the Softpaq ID from entry string
        $rs_RplSolutionID = $pssSolution.split(' ')[0]
        $rs_Node = $rs_XMLSolutions | Where-Object { $_.id -eq $rs_SolutionID }
        $rs_ssNode = $rs_ssXMLSolutions | Where-Object { $_.id -eq $rs_RplSolutionID } # find the superseding node

        if ( $rs_SolutionCategory -match "^bios*" ) {
            $rs_ssBIOSStringList = $pssSolution.split('/').Trim()            
            $rs_BIOSVerString = $pssSolution.split('\(')[1].Substring(0,3)+' Ver. '+$rs_ssBIOSStringList[1]
            $rs_BIOSDate = $rs_ssBIOSStringList[2].split('-')
            $rs_BIOSDate = $rs_BIOSDate[1]+'/'+$rs_BIOSDate[2]+'/'+$rs_BIOSDate[0]
            $Script:xmlContent.ImagePal.SystemInfo.System.BiosVersion2 = $rs_BIOSVerString
            $Script:xmlContent.ImagePal.SystemInfo.System.BiosDate = $rs_BIOSDate  
            $Script:xmlContent.ImagePal.SystemInfo.System.Solutions.UpdateInfo.IdRef = $rs_RplSolutionID
            $rs_replaced = $true
        } else {
            # we need to handle UWP apps versions, so let's find out the supersed Softpaq UWP's
            # by retrieving the CVA file contents for the Store Apps section list
            Try {
                $Error.Clear()
                $rs_lineNum = ((get-pscallstack)[0].Location -split " line ")[1] # get code line # in case of failure
                $rs_spqMetadata = Get-SoftpaqMetadata $rs_RplSolutionID -ErrorAction Stop  # get CVA file for this Softpaq
            } catch {
                $rs_Err = $error[0].exception          # OPTIONAL: $error[0].exception.gettype().fullname 
                write-host "$($rs_RplSolutionID): Get-SoftpaqMetadata exception: on line number $($rs_lineNum) - $($rs_Err)" 
                return $False
            } # catch
            $rx_DockCheck = $false
            switch -regex ( $rs_SolutionCategory ) {
                '^Driver*'  { 
                    $rx_DevCount = Update_XMLDevices $rs_Node $rs_ssNode                    
                    $rx_UWPCount = Update_XMLUWPApp $rs_Node $rs_ssNode $pspqMetadata 
                }
                '^Software*'  { 
                    $rs_replaced = Update_XMLSoftwareInstalled $rs_Node $rs_ssNode
                    $rx_UWPCount = Update_XMLUWPApp $rs_Node $rs_ssNode $pspqMetadata
                    $rx_devCount = Update_XMLDevices $rs_Node $rs_ssNode
                }
                '^Dock*'  { 
                    $rx_DockCheck = $true
                    $rx_UWPCount = Update_XMLUWPApp $rs_Node $rs_ssNode $pspqMetadata
                    $rx_DevCount = Update_XMLDevices $rs_Node $rs_ssNode                    
                }
                'firmware'  { 
                    if ( -not $rx_DockCheck ) {
                        $rs_replaced = Update_XMLDevices $rs_Node $rs_ssNode
                    }
                }
            } # switch -regex ( $rs_SolutionCategory )
        } # else if ( $rs_SolutionCategory -match "^bios*" )
        # finally replace the current Softpaq with the chosen Softpaq in file
        $rs_Node.ParentNode.InsertAfter($rs_ssNode,$rs_Node)    # and add it to the list
        $rs_Node.ParentNode.RemoveChild($rs_Node) | Out-Null    # then remove the other one
    } # if ( $pssSolution.length -gt 0 )

    $Script:xmlContent.Save((Convert-Path $Script:RefFilePath))
    $rs_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")

    $rs_SpqCount = Show_SoftpaqList $pFormSolutionsList $rs_XMLSolutions $pCategories $pName2match

    if ( $Script:DebugInfo ) { ">> Replace_Solution()" | out-file -append $Script:LogFilePath }

    return $rs_replaced
} # Function Replace_Solution

<#################################################################################
    Function Show_ContextFileMenu
    displays CVA or Release Notes (html) file based on context menu click
    Args: $pSolution                # solution/Softpaq to remove or replace (if !$null)        
        $pFileType                  # 'cva'|'html'
        $pWhichNode                 # $true to look in /Solutions, $false to look in superseded
    Return: count of displayed items in Solutions list box
#################################################################################>
Function Show_ContextFileMenu {
    [CmdletBinding()] param( $pSolution, $pFileType, $pWhichNode )

    if ( $pWhichNode ) {    # $true means /Solutions
        $sc_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
    } else {                # $false means /superseded-Solutions
        $sc_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions-Superseded/UpdateInfo")
    }
    <# /Solutions entries in reference file contain:
        <Url>ftp.hp.com/pub/softpaq/sp147501-148000/sp147684.exe</Url>
        <ReleaseNotesUrl>ftp.hp.com/pub/softpaq/sp147501-148000/sp147684.html</ReleaseNotesUrl>
        <CvaUrl>ftp.hp.com/pub/softpaq/sp147501-148000/sp147684.cva</CvaUrl>
    #>
    foreach ( $iSoftpaq in $sc_XMLSolutions ) {
        if ( $iSoftpaq.Id -like $pSolution ) {
            switch ( $pFileType ) {
                'cva'   { $url = $($iSoftpaq.CvaUrl) ; 
                    $sc_file2open = "$($iSoftpaq.Id).cva" ;
                    Invoke-WebRequest $url -OutFile ".\$(Split-Path -Leaf $url)"
                    Start-Process ".\\$sc_file2open"
                }
                'html'  { $url = $($iSoftpaq.ReleaseNotesUrl) ; 
                    $sc_currLoc = get-location
                    Invoke-WebRequest $url -OutFile ".\$(Split-Path -Leaf $url)"
                    $sc_file2open = "$($iSoftpaq.Id).html"
                    $sc_fullpath = $sc_currLoc.Path.replace('\','/')+'/'+$sc_file2open
                    Start-Process file:'//'$sc_fullpath
                }
            } # switch ( $pFileType )
            break
        } # if ( $iSoftpaq.Id -like $pSolution )
    } # foreach ( $iSoftpaq in $sc_XMLSolutions )

} # Function Show_ContextFileMenu

<#################################################################################
    Function Init_Repo
    initializes a HPIA repository
    Args: $pStartLoc         # initial location to search for a repo folder
    Return: selected repository folder
#################################################################################>
Function Init_Repo {
    [CmdletBinding()] param( $pStartLoc )

    $ir_Return = @{}                    # function returns 2 items in array
    $ir_Return.Folder = ""
    $ir_Return.Message = "Repository Folder not Selected"

    $ir_foldername = New-Object System.Windows.Forms.FolderBrowserDialog 
    $ir_foldername.Description = "Select a Repository folder"
    $ir_foldername.SelectedPath = $pStartLoc
    if( $ir_foldername.ShowDialog() -eq "OK" ) {
        $ir_Return.Folder = $ir_foldername.SelectedPath
        $ir_CurrLocSaved = Get-location                
        Try {
            $Error.Clear()
            set-location $ir_Return.Folder
            # is this already a valid repository?
            $ir_repositoryInfo = Get-RepositoryInfo -EA SilentlyContinue
            $ir_FilterMsg = "$($ir_Return.Folder) is already a repository. Is it OK to clear existing filters?"
            $ir_askOKCancel = [System.Windows.Forms.MessageBox]::Show($ir_FilterMsg,'Asterisk','OKCancel','Asterisk')
            if ( $ir_askOKCancel -eq 'Ok' ) {            
                $ir_RepoFilters = (Get-RepositoryInfo).Filters
                foreach ( $ir_Platform in $ir_RepoFilters.platform) {
                    Remove-RepositoryFilter -platform $ir_Platform -yes 6>&1
                }          
                $ir_Return.Message = 'Existing Repository. Cleared current filters'
                if ( $Script:DebugInfo ) { 'Existing Repository. Cleared current filters' | out-file -append $Script:LogFilePath }
                # next remove traces of previous 'sync's
                $ir_repoCacheFolder = "$($ir_Return.Folder)\.repository\cache"
                if ( Test-Path $ir_repoCacheFolder) {                   
                    Remove-Item -Path "$($ir_repoCacheFolder)" -Recurse -Force
                    if ( $Script:DebugInfo ) { '... and existing cached files' | out-file -append $Script:LogFilePath }
                }  
            } else {
                $ir_Return.Message = 'Existing Repository. Filters not cleared'
            } # if ( $ir_askOKCancel -eq 'Ok' )
        } Catch {
            write-host $error[0].exception 
            Initialize-Repository
            # configuring the repo for HPIA's use
            Set-RepositoryConfiguration -setting OfflineCacheMode -cachevalue Enable 6>&1   
            # configuring to create 'Contents.CSV' after every Sync -- NOTE: we won't do syncs here
            Set-RepositoryConfiguration -setting RepositoryReport -Format csv 6>&1              
            $ir_Return.Message = 'Repository created and initialized'
        } # Try Catch
        set-location $ir_CurrLocSaved
    } # if( $ir_foldername.ShowDialog() -eq "OK" )

    return $ir_Return
} # Function Init_Repo

<#################################################################################
    Function FindPlatform_GUI
    Here we ask the user to select a new device and return the name (and SysID)
#################################################################################>
Function FindPlatform_GUI {

    $fp_FormWidth = 400
    $fp_FormHeigth = 400
    $fp_Offset = 20
    $fp_FieldHeight = 20
    $fp_PathFieldLength = 200

    $fp_EntryForm = New-Object System.Windows.Forms.Form
    $fp_EntryForm.MaximizeBox = $False ; $fp_EntryForm.MinimizeBox = $False #; $fp_EntryForm.ControlBox = $False
    $fp_EntryForm.Text = "Search for Device to Manage"
    $fp_EntryForm.Width = $fp_FormWidth ; $fp_EntryForm.height = 400 ; $fp_EntryForm.Autosize = $true
    $fp_EntryForm.StartPosition = 'CenterScreen'
    $fp_EntryForm.Topmost = $true
    $fp_EntryForm.Add_KeyDown({
        if ($_.KeyCode -eq "Escape") {  # if escape, exit
            $fp_EntryForm.Close()
        }
    })
    # ------------------------------------------------------------------------
    # find and add model entry
    $fp_EntryId = New-Object System.Windows.Forms.Label
    $fp_EntryId.Text = "System"
    $fp_EntryId.location = New-Object System.Drawing.Point($fp_Offset,$fp_Offset) # (from left, from top)
    $fp_EntryId.Size = New-Object System.Drawing.Size(60,20)                   # (width, height)

    $fp_EntryModel = New-Object System.Windows.Forms.TextBox
    $fp_EntryModel.Text = ""
    $fp_EntryModel.Multiline = $false 
    $fp_EntryModel.location = New-Object System.Drawing.Point(($fp_Offset+70),($fp_Offset-4)) # (from left, from top)
    $fp_EntryModel.Size = New-Object System.Drawing.Size($fp_PathFieldLength,$fp_FieldHeight)# (width, height)
    $fp_EntryModel.ReadOnly = $False
    $fp_EntryModel.Name = "Model Name"
    $fp_EntryModel.add_MouseHover($ShowHelp)
    $fp_EntryModel.Add_KeyDown({
        if ($_.KeyCode -eq "Enter") {
            $fp_SearchGo.PerformClick()
        }
    })
    # add 'wait...' message label
    $fp_Entrymsg = New-Object System.Windows.Forms.Label
    $fp_Entrymsg.ForeColor = 'blue'
    $fp_Entrymsg.location = New-Object System.Drawing.Point($fp_Offset,($fp_Offset+20)) # (from left, from top)
    $fp_Entrymsg.Size = New-Object System.Drawing.Size(160,40)                   # (width, height)
    $fp_Entrymsg.Text = 'Use [Search] to find platform, or [Load] to use saved file'
    # add 'search' button
    $fp_SearchGo = New-Object System.Windows.Forms.Button
    $fp_SearchGo.Location = New-Object System.Drawing.Point(($fp_PathFieldLength+$fp_Offset+80),($fp_Offset-6))
    $fp_SearchGo.Size = New-Object System.Drawing.Size(75,23)
    $fp_SearchGo.Text = 'Search'
    $fp_SearchGo.Add_Click( {
        if ( $fp_EntryModel.Text ) {
            $fp_AddEntryList.Items.Clear()
            $fp_Entrymsg.Text = "Retrieving Reference File... Please, wait"
            $lModels = Get-HPDeviceDetails -Like -Name $fp_EntryModel.Text    # find all models matching entered text
            if ( $lModels.count -eq 0 ) {
                $fp_Entrymsg.Text = 'No matching platforms found'
            } else {
                foreach ( $iModel in ($lModels | sort-Object -Property Name) ) { 
                    [void]$fp_AddEntryList.Items.Add($iModel.SystemID+':'+$iModel.Name) 
                }
                $fp_Entrymsg.Text = ''                
            }
            $fp_EntryForm.AcceptButton = $fp_okButton
        } # if ( $fp_EntryModel.Text )
    } )
    # add 'models list' list box
    $fp_AddEntryList = New-Object System.Windows.Forms.ListBox
    $fp_AddEntryList.Name = 'Entries'
    $fp_AddEntryList.Autosize = $false
    $fp_AddEntryList.location = New-Object System.Drawing.Point($fp_Offset,80)  # (from left, from top)
    $fp_AddEntryList.Size = New-Object System.Drawing.Size(($fp_FormWidth-80),($fp_FormHeigth/2)) # (width, height)
    $fp_AddEntryList.add_click( { $fp_okButton.Enabled = $true })
    $fp_AddEntryList.add_doubleClick( { $fp_okButton.PerformClick() } )

    # ------------------------------------------------------------------------
    #$fp_FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ InitialDirectory = [Environment]::GetFolderPath('Desktop') }
    $fp_FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ InitialDirectory = $Script:CacheDir }
    #$fp_FileBrowser.InitialDirectory = $v_HPIAPath
    $fp_FileBrowser.Title = "Locate XML reference file"
    $fp_FileBrowser.Filter = "xml file | *.xml"

    $fp_LoadFile = New-Object System.Windows.Forms.Button
    $fp_LoadFile.Location = New-Object System.Drawing.Point(($fp_Offset),($fp_FormHeigth-80))
    $fp_LoadFile.Size = New-Object System.Drawing.Size(75,23)
    $fp_LoadFile.Text = 'Load File'
    $fp_LoadFile.Add_Click( {
        $fp_FileBrowse = $fp_FileBrowser.ShowDialog()
        if ( $fp_FileBrowse -eq 'OK' ) {
            $fp_filePath = $fp_FileBrowser.FileName
            [void]$fp_AddEntryList.Items.Add($fp_filePath) 
            $fp_AddEntryList.SelectedIndex = 0
            $fp_okButton.Enabled = $true
            $fp_okButton.PerformClick()
        } 
    } )
    # ------------------------------------------------------------------------
    # show the dialog, and once user preses OK, add the model and create the flag file for addons
    $fp_okButton = New-Object System.Windows.Forms.Button
    $fp_okButton.Location = New-Object System.Drawing.Point(($fp_FormWidth-120),($fp_FormHeigth-80))
    $fp_okButton.Size = New-Object System.Drawing.Size(75,23)
    $fp_okButton.Text = 'OK'
    $fp_okButton.Enabled = $False
    $fp_okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $fp_cancelButton = New-Object System.Windows.Forms.Button
    $fp_cancelButton.Location = New-Object System.Drawing.Point(($fp_FormWidth-200),($fp_FormHeigth-80))
    $fp_cancelButton.Size = New-Object System.Drawing.Size(75,23)
    $fp_cancelButton.Text = 'Cancel'
    $fp_cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::CANCEL

    $fp_EntryForm.AcceptButton = $fp_SearchGo           # enable 'Enter' at the platform name field
    $fp_EntryForm.CancelButton = $fp_cancelButton

    $fp_EntryForm.Controls.AddRange(@($fp_EntryId,$fp_EntryModel,$fp_Entrymsg,$fp_SearchGo))
    $fp_EntryForm.Controls.AddRange(@($fp_AddEntryList,$fp_LoadFile,$fp_cancelButton, $fp_okButton))

    $fp_Result = $fp_EntryForm.ShowDialog()

    if ($fp_Result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $fp_AddEntryList.SelectedItem
    } 
} # Function FindPlatform_GUI

<#################################################################################
    Function Create_Form
    this is the core of the script
#################################################################################>
Function Create_Form {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -assembly System.Windows.Forms

    $FormWidth = 800
    $FormHeight = 640
    $LeftOffset = 20
    $TopOffset = 20

    #----------------------------------------------------------------------------------
    # Create container form
    $cf_Form = New-Object System.Windows.Forms.Form
    $cf_Form.Text = "Reference File editor - "+$ReFileVersion                   # shows on the header
    $cf_Form.Name = 'MyForm'                                  # this is how the form can be addressed by code
    $cf_Form.Width = $FormWidth
    $cf_Form.height = $FormHeight
    $cf_Form.Autosize = $false                                # ... try setting to $true
    $cf_Form.StartPosition = 'CenterScreen'                   # ... Options: CenterParent, CenterScreen, Manual (use Location property), 
    #----------------------------------------------------------------------------------
    # Add 'OS' label
    $cf_OSLabel = New-Object System.Windows.Forms.Label
    $cf_OSLabel.Text = "OS"
    $cf_OSLabel.location = New-Object System.Drawing.Point($LeftOffset,$TopOffset)  # (from left, from top)
    $cf_OSLabel.Size = New-Object System.Drawing.Size(40,20)                      # (width, height)
    $cf_OSLabel.TextAlign = "BottomCenter"
    <# BottomCenter,BottomLeft,BottomRight,MiddleCenter,MiddleLeft,MiddleRight,TopCenter,TopLeft,TopRight #>
    
    #----------------------------------------------------------------------------------
    # Add 'OS' data field
    $cf_OSList = New-Object System.Windows.Forms.ComboBox
    $cf_OSList.Size = New-Object System.Drawing.Size(60,20)                  # (width, height)
    $cf_OSList.Location  = New-Object System.Drawing.Point(($LeftOffset+50), ($TopOffset+4))
    $cf_OSList.DropDownStyle = "DropDownList"
    $cf_OSList.Name = "OSList"
    [void]$cf_OSList.Items.AddRange($Script:OSs)
    $cf_OSList.SelectedItem = $Script:OSs[0]
    $cf_OSList.Add_SelectedIndexChanged( {
        $cf_OSVerList.Items.Clear()
        switch ( $cf_OSList.Text ) {
            '10' {
                [void]$cf_OSVerList.Items.AddRange($Script:OS10Vers)
                $cf_OSVerList.SelectedItem = $Script:OS10Vers[3]              # set visible default entry
            }
            '11' {
                [void]$cf_OSVerList.Items.AddRange($Script:OS11Vers)
                $cf_OSVerList.SelectedItem = $Script:OS11Vers[1]            # set visible default entry
            }
        }
    }) # $cf_OSList.Add_SelectedIndexChanged
    #----------------------------------------------------------------------------------
    # Add 'OS Version' label
    $cf_OSVerLabel = New-Object System.Windows.Forms.Label
    $cf_OSVerLabel.Text = "Version"
    $cf_OSVerLabel.location = New-Object System.Drawing.Point(($LeftOffset+110),$TopOffset)  # (from left, from top)
    $cf_OSVerLabel.Size = New-Object System.Drawing.Size(60,20)   # (width, height)
    $cf_OSVerLabel.TextAlign = "BottomCenter"
    # Add 'OS Version' data field
    $cf_OSVerList = New-Object System.Windows.Forms.ComboBox
    $cf_OSVerList.Size = New-Object System.Drawing.Size(60,20)      # (width, height)
    $cf_OSVerList.Location  = New-Object System.Drawing.Point(($LeftOffset+170), ($TopOffset+4))
    $cf_OSVerList.DropDownStyle = "DropDownList"
    $cf_OSVerList.Name = "Version"
    [void]$cf_OSVerList.Items.AddRange($Script:OS10Vers)
    $cf_OSVerList.SelectedItem = $Script:OS10Vers[3]                  # set visible default entry
    # Add 'Windows' label
    $cf_Message = New-Object System.Windows.Forms.Label  
    $cf_Message.location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+30))  # (from left, from top)
    $cf_Message.Size = New-Object System.Drawing.Size(240,20)  # (width, height)
    $cf_Message.Name = 'Message'
    $cf_Message.ForeColor = 'blue'
    $cf_Message.Text = "Please, Confirm OS and OS Version first"
    $cf_Message.BorderStyle = 'none'
    $cf_Form.Controls.AddRange(@($cf_OSLabel,$cf_OSList,$cf_OSVerLabel,$cf_OSVerList,$cf_Message))

    #----------------------------------------------------------------------------------
    # Add platform Select Button
    $cf_SearchButton = New-Object System.Windows.Forms.Button
    $cf_SearchButton.Text = "Select Platform"
    $cf_SearchButton.location = New-Object System.Drawing.Point(($LeftOffset+280),$TopOffset)  # (from left, from top)
    $cf_SearchButton.AutoSize = $true
    $cf_SearchButton.TextAlign = "MiddleRight"    
    $cf_SearchButton.add_click( {
        $cf_PlatformReturn = FindPlatform_GUI   #returns platform id:name or xml reference file
        if ( $null -ne $cf_PlatformReturn ) { 
            $cf_RefFileMsg.Text = "... Please, Wait"
            if ( $cf_PlatformReturn -match "xml$") {    # NEW: if return is an XML file, we'll work on that instead                
                $cf_RefFileSelected = Get_LocalFile $cf_PlatformReturn
                $cf_Msg = "Reference File selected (.bak made)"            
                $Script:RefFilePath = $cf_PlatformReturn
                # compile platform Text file <SysID:Model name> for field display
                $cf_PlatformFileName = [System.IO.Path]::GetFileNameWithoutExtension($cf_PlatformReturn)
                $cf_PlatformID = $cf_PlatformFileName.Substring(0,4)
                $cf_PlatformName = ([array](Get-HPDeviceDetails -platform $cf_PlatformID)[0]).Name
                $cf_SelectedPlatform.Text = $cf_PlatformID+':'+$cf_PlatformName
            } else {
                $cf_SelectedPlatform.Text = $cf_PlatformReturn
                $Script:OS = 'Win'+$cf_OSList.SelectedItem  # make it 'win10', 'win11' as req'd by CMSL cmds
                $Script:OSVer = $cf_OSVerList.SelectedItem
                $PlatformID = $cf_SelectedPlatform.Text.substring(0,4)
                $Script:RefFilePath = Get_FileFromHP $PlatformID $Script:OS $Script:OSVer
                $cf_Msg = "Reference File is a working copy"
            } # else if ( $cf_PlatformReturn -match "xml$")

            if ( $Script:RefFilePath ) {
                $cf_RefFileMsg.Text = $cf_Msg
                $cf_RefFilePath.Text = $Script:RefFilePath
                $cf_RefFilePath.Select($cf_RefFilePath.Text.Length, 0)  # show end of path
                $cf_RefFilePath.ScrollToCaret()
                $Script:xmlContent = [xml](Get-Content -Path $Script:RefFilePath)
                $cf_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
                $cf_Categories = @('BIOS','Driver','Software','Firmware','Dock')  # default to ALL
                $cf_SpqCount = Show_SoftpaqList $cf_SoftpaqsList $cf_XMLSolutions $cf_Categories $cf_SolutionSearch.Text
                $cf_CurrentSpqsMsg.Text = "ctl-Click for multi-select"
                $cf_CategoryBIOS.Checked = $true ; $cf_CategoryBIOS.Enabled = $true
                $cf_CategoryDriver.Checked = $true ; $cf_CategoryDriver.Enabled = $true
                $cf_CategorySoftware.Checked = $true ; $cf_CategorySoftware.Enabled = $true
                $cf_CategoryFirmware.Checked = $true ; $cf_CategoryFirmware.Enabled = $true
                $cf_CategoryDock.Checked = $true ; $cf_CategoryDock.Enabled = $true 
                $cf_RefreshCatButton.Enabled = $true               # enable category 'refresh' button
                $cf_SolutionSearch.Enabled = $true              # enable solution search field
                $cf_SolutionGo.Enabled = $true                  # enable solution search 'Go' button
                $cf_Platform = $cf_SelectedPlatform.Text            
            } else {
                $cf_RefFileMsg.Text = 'Error 404: Reference File not found'
                $cf_Platform = $null
            } # else if ( $Script:RefFilePath )
            $cf_CurrentSpqsMsg.Text = ""  
        } # if ( $null -ne $cf_PlatformReturn )
        $cf_actionMsg.Text = ""  # in case we start a new file edit and a there is a leftover msg
    } ) # $cf_SearchButton.add_click

    # Add 'selected platform' data field
    $cf_SelectedPlatform = New-Object System.Windows.Forms.TextBox
    $cf_SelectedPlatform.location = New-Object System.Drawing.Point(($LeftOffset+390),($TopOffset+2))  # (from left, from top)
    $cf_SelectedPlatform.Size = New-Object System.Drawing.Size(300,20)  # (width, height)
    $cf_SelectedPlatform.BorderStyle = 'Fixed3D'                # Options: Fixed3D, FixedSingle, None (default)
    $cf_SelectedPlatform.Text = 'Platform not selected...'
    $cf_SelectedPlatform.ReadOnly = $true
    $cf_Form.Controls.AddRange(@($cf_SearchButton,$cf_SelectedPlatform))

    ###################################################################################
    # create group box to hold all Softpaq data stuff
    ###################################################################################
    $SolutionGroupBox = New-Object System.Windows.Forms.GroupBox
    $SolutionGroupBox.location = New-Object System.Drawing.Point(($LeftOffset),($TopOffset+50)) # (from left, from top)
    $SolutionGroupBox.Size = New-Object System.Drawing.Size(700,360)                    # (width, height)

    #----------------------------------------------------------------------------------
    # Add 'Windows' label
    $cf_CategoryLabel = New-Object System.Windows.Forms.Label
    $cf_CategoryLabel.Text = "Filter`r`n by Category"
    $cf_CategoryLabel.location = New-Object System.Drawing.Point(($LeftOffset-5),($TopOffset))  # (from left, from top)
    $cf_CategoryLabel.Size = New-Object System.Drawing.Size(80,30)                      # (width, height)
    $cf_CategoryLabel.TextAlign = "BottomCenter"
    
    # Add category Checkboxes
    $cf_CategoryBIOS = New-Object System.Windows.Forms.CheckBox ;     $cf_CategoryBIOS.Enabled = $false
    $cf_CategoryDriver = New-Object System.Windows.Forms.CheckBox ;   $cf_CategoryDriver.Enabled = $false
    $cf_CategorySoftware = New-Object System.Windows.Forms.CheckBox ; $cf_CategorySoftware.Enabled = $false
    $cf_CategoryFirmware = New-Object System.Windows.Forms.CheckBox ; $cf_CategoryFirmware.Enabled = $false
    $cf_CategoryDock = New-Object System.Windows.Forms.CheckBox ;     $cf_CategoryDock.Enabled = $false

    $cf_CategoryBIOS.Text = 'BIOS' ;            $cf_CategoryBIOS.Autosize = $true
    $cf_CategoryBIOS.Location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+40))   # (from left, from top)
    $cf_CategoryDriver.Text = 'Driver' ;        $cf_CategoryDriver.Autosize = $true
    $cf_CategoryDriver.Location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+60))   # (from left, from top)
    $cf_CategorySoftware.Text = 'Software' ;    $cf_CategorySoftware.Autosize = $true
    $cf_CategorySoftware.Location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+80))   # (from left, from top)
    $cf_CategoryFirmware.Text = 'Firmware' ;    $cf_CategoryFirmware.Autosize = $true
    $cf_CategoryFirmware.Location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+100))   # (from left, from top)
    $cf_CategoryDock.Text = 'Dock' ;            $cf_CategoryDock.Autosize = $true
    $cf_CategoryDock.Location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+120))   # (from left, from top)
    # Add Category 'Refresh' Button
    $cf_RefreshCatButton = New-Object System.Windows.Forms.Button
    $cf_RefreshCatButton.Text = "Refresh"  ;       $cf_RefreshCatButton.AutoSize = $true
    $cf_RefreshCatButton.location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+160))  # (from left, from top)    
    $cf_RefreshCatButton.Enabled = $false
    $cf_RefreshCatButton.add_click( {
        # refresh /Categories list and repopulate list
        $cf_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
        $cf_Categories = @()
        if ( $cf_CategoryBIOS.checked ) { $cf_Categories += 'BIOS'}
        if ( $cf_CategoryDriver.checked ) { $cf_Categories += 'Driver'}
        if ( $cf_CategorySoftware.checked ) { $cf_Categories += 'Software'}
        if ( $cf_CategoryFirmware.checked ) { $cf_Categories += 'Firmware'}
        if ( $cf_CategoryDock.checked ) { $cf_Categories += 'Dock'}
        $cf_SpqCount = Show_SoftpaqList $cf_SoftpaqsList $cf_XMLSolutions $cf_Categories $cf_SolutionSearch.Text
        $cf_SoftpaqField.Text = ""               # clear the to be replaced entry field
        $cf_SoftpaqReplace.Text = ""        # clear the replace entry field
        $cf_CurrentSpqsMsg.Text = "Done"    # mark the action as 'done'
        $cf_ssList.Items.Clear()            # clear out the solutions supersede listbox
    } ) # $cf_RefreshCatButton.add_click
    # Add 'Current Softpaqs' action message label
    $cf_CurrentSpqsMsg = New-Object System.Windows.Forms.Label
    $cf_CurrentSpqsMsg.location = New-Object System.Drawing.Point($LeftOffset,($TopOffset+200))  # (from left, from top)
    $cf_CurrentSpqsMsg.Size = New-Object System.Drawing.Size(80,40) # (width, height)
    $cf_CurrentSpqsMsg.ForeColor = 'blue'
    $cf_CurrentSpqsMsg.TextAlign = "TopLeft"

    $SolutionGroupBox.Controls.Add($cf_CategoryLabel)
    $SolutionGroupBox.Controls.AddRange(@($cf_CategoryLabel,$cf_CategoryBIOS,$cf_CategoryDriver,$cf_CategorySoftware,$cf_CategoryFirmware,$cf_CategoryDock))
    $SolutionGroupBox.Controls.AddRange(@($cf_RefreshCatButton,$cf_CurrentSpqsMsg))

    $cf_Form.Controls.AddRange(@($SolutionGroupBox))

    #----------------------------------------------------------------------------------
    # Add 'Current Solutions' label
    $cf_CurrentSpqsLabel = New-Object System.Windows.Forms.Label
    $cf_CurrentSpqsLabel.Text = "Current Solutions"
    $cf_CurrentSpqsLabel.location = New-Object System.Drawing.Point(($LeftOffset+90),($TopOffset))  # (from left, from top)
    $cf_CurrentSpqsLabel.AutoSize = $true
    $cf_CurrentSpqsLabel.TextAlign = "BottomCenter"
    
    # Add 'Softpaq Search' text field
    $cf_SolutionSearch = New-Object System.Windows.Forms.TextBox
    $cf_SolutionSearch.location = New-Object System.Drawing.Point(($LeftOffset+195),($TopOffset))  # (from left, from top)
    $cf_SolutionSearch.Size = New-Object System.Drawing.Size(120,20)  # (width, height)
    $cf_SolutionSearch.BorderStyle = 'FixedSingle'                # Options: Fixed3D, FixedSingle, None (default)
    $cf_SolutionSearch.Text = ''
    $cf_SolutionSearch.Enabled = $false
    $cf_SolutionSearch.Add_KeyDown({
        if ($_.KeyCode -eq "Enter") {
             $cf_SolutionGo.PerformClick()
        }
    })
    $cf_SolutionGo = New-Object System.Windows.Forms.Button
    $cf_SolutionGo.Text = "GO"
    $cf_SolutionGo.location = New-Object System.Drawing.Point(($LeftOffset+316),($TopOffset))  # (from left, from top)
    $cf_SolutionGo.Size = New-Object System.Drawing.Size(30,20)  # (width, height)
    $cf_SolutionGo.Enabled = $false
    $cf_SolutionGo.add_click({
        $cf_Categories = @()
        if ( $cf_CategoryBIOS.checked ) { $cf_Categories += 'BIOS'}
        if ( $cf_CategoryDriver.checked ) { $cf_Categories += 'Driver'}
        if ( $cf_CategorySoftware.checked ) { $cf_Categories += 'Software'}
        if ( $cf_CategoryFirmware.checked ) { $cf_Categories += 'Firmware'}
        if ( $cf_CategoryDock.checked ) { $cf_Categories += 'Dock'}
        $cf_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
        $cf_SpqCount = Show_SoftpaqList $cf_SoftpaqsList $cf_XMLSolutions $cf_Categories $cf_SolutionSearch.Text
    })
    # Add 'Softpaqs' ListBox
    $cf_SoftpaqsList = New-Object System.Windows.Forms.ListBox
    $cf_SoftpaqsList.Name = 'Softpaqs'
    $cf_SoftpaqsList.Autosize = $false
    $cf_SoftpaqsList.location = New-Object System.Drawing.Point(($LeftOffset+90),40)  # (from left, from top)
    $cf_SoftpaqsList.Size = New-Object System.Drawing.Size(260,($FormHeight-330)) # (width, height)
    $cf_SoftpaqsList.HorizontalScrollBar="Auto"
    $cf_SoftpaqsList.SelectionMode = 'MultiExtended'
    $cf_SoftpaqsList.add_click( {
        $cf_actionMsg.Text = ""
        $cf_CurrentSpqsMsg.Text = "ctl-Click for multi-select"
        if ( $cf_SoftpaqsList.SelectedItems.count -eq 1 ) {
            $cf_SoftpaqField.Text = $cf_SoftpaqsList.SelectedItem
            $cf_SoftpaqID = $cf_SoftpaqsList.SelectedItem.split(' ')[0]
            List_Supersedes $cf_ssList $cf_SoftpaqID
            $cf_SoftpaqReplace.clear()
            $cf_actionButton.Enabled = $true
            $cf_actionButton.Text = "Remove"
        } elseif ( $cf_SoftpaqsList.SelectedItems.count -gt 1 ) {
            $cf_SoftpaqField.Text = ''
        }
    } )
    # Add context menu to list to access CVA or HTML files
    $contextMenuStrip1 = New-Object System.Windows.Forms.ContextMenuStrip
    $contextMenuStrip1.Items.Add("CVA").add_Click({ 
        if ( $cf_SoftpaqsList.SelectedIndex -ge 0 ) { 
            Show_ContextFileMenu $cf_SoftpaqsList.SelectedItem.split(' ')[0] 'cva' $true
        }
    })
    $contextMenuStrip1.Items.Add("HTML").add_Click({ 
        if ( $cf_SoftpaqsList.SelectedIndex -ge 0 ) {
            Show_ContextFileMenu $cf_SoftpaqsList.SelectedItem.split(' ')[0] 'html' $true
        }
    })
    $cf_SoftpaqsList.ContextMenuStrip = $contextMenuStrip1

    $SolutionGroupBox.Controls.AddRange(@($cf_CurrentSpqsLabel,$cf_SolutionSearch,$cf_SolutionGo,$cf_SoftpaqsList))

    #----------------------------------------------------------------------------------
    # Add 'Superseded Softpaqs List' label
    $cf_ssLabel = New-Object System.Windows.Forms.Label
    $cf_ssLabel.Text = "Supersedes"
    $cf_ssLabel.location = New-Object System.Drawing.Point(($LeftOffset+360),($TopOffset))  # (from left, from top)
    $cf_ssLabel.AutoSize = $true
    $cf_ssLabel.TextAlign = "BottomCenter"
    # Add 'Superseded Softpaqs' ListBox
    $cf_ssList = New-Object System.Windows.Forms.ListBox
    $cf_ssList.Name = 'Superseded List'
    #$cf_ssList.Autosize = $false
    $cf_ssList.location = New-Object System.Drawing.Point(($LeftOffset+360),($TopOffset+20))  # (from left, from top)
    $cf_ssList.Size = New-Object System.Drawing.Size(300,120) # (width, height)
    $cf_ssList.HorizontalScrollBar="Auto"
    $cf_ssList.add_click( {
        $cf_SoftpaqReplace.Text = $cf_ssList.SelectedItem
        if ( $cf_ssList.SelectedItems.count -gt 0 ) {
            $cf_actionButton.Enabled = $true 
            $cf_actionButton.Text = "Replace"
        }
    } )
    # Add context menu to list to access CVA or HTML files
    $contextMenuStrip2 = New-Object System.Windows.Forms.ContextMenuStrip
    $contextMenuStrip2.Items.Add("CVA").add_Click({ 
        if ( $cf_ssList.SelectedIndex -ge 0 ) { 
            Show_ContextFileMenu $cf_ssList.SelectedItem.split(' ')[0] 'cva' $false
        }
    })
    $contextMenuStrip2.Items.Add("HTML").add_Click({ 
        if ( $cf_ssList.SelectedIndex -ge 0 ) {
            Show_ContextFileMenu $cf_ssList.SelectedItem.split(' ')[0] 'html' $false
        }
    })
    $cf_ssList.ContextMenuStrip = $contextMenuStrip2            # add the right-click menu to listbox

    $SolutionGroupBox.Controls.AddRange(@($cf_ssLabel,$cf_ssList))

    ###################################################################################
    # create group box to hold the Softpaq and replacement entries, and replace/remove button
    ###################################################################################
    $ReplaceGroupBox = New-Object System.Windows.Forms.GroupBox
    $ReplaceGroupBox.location = New-Object System.Drawing.Point(($LeftOffset+360),($TopOffset+140)) # (from left, from top)
    $ReplaceGroupBox.Size = New-Object System.Drawing.Size(300,180)                    # (width, height)
    $ReplaceGroupBox.Text = "Manage Softpaq Entry"

    #----------------------------------------------------------------------------------
    # Add Selected Softpaq label
    $cf_SpqLabel = New-Object System.Windows.Forms.Label
    $cf_SpqLabel.Text = "Softpaq"
    $cf_SpqLabel.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset))  # (from left, from top)
    $cf_SpqLabel.AutoSize = $true
    $cf_SpqLabel.TextAlign = "BottomCenter"
    # Add Selected Softpaq field
    $cf_SoftpaqField = New-Object System.Windows.Forms.TextBox
    $cf_SoftpaqField.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset+20))  # (from left, from top)
    $cf_SoftpaqField.Size = New-Object System.Drawing.Size(280,20)  # (width, height)
    $cf_SoftpaqField.BorderStyle = 'FixedSingle'                # Options: Fixed3D, FixedSingle, None (default)
    # Add Selected Softpaq replace with label
    $cf_SpqReplaceLabel = New-Object System.Windows.Forms.Label
    $cf_SpqReplaceLabel.Text = "Replace with"
    $cf_SpqReplaceLabel.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset+40))  # (from left, from top)
    $cf_SpqReplaceLabel.AutoSize = $true
    $cf_SpqReplaceLabel.TextAlign = "BottomCenter"
    # Add Selected Softpaq field
    $cf_SoftpaqReplace = New-Object System.Windows.Forms.TextBox
    $cf_SoftpaqReplace.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset+60))  # (from left, from top)
    $cf_SoftpaqReplace.Size = New-Object System.Drawing.Size(280,20)  # (width, height)
    $cf_SoftpaqReplace.BorderStyle = 'FixedSingle'                # Options: Fixed3D, FixedSingle, None (default)
    # Add 'Replace' Button
    $cf_actionButton = New-Object System.Windows.Forms.Button
    $cf_actionButton.Text = ""
    $cf_actionButton.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset+90))  # (from left, from top)
    $cf_actionButton.AutoSize = $true
    $cf_actionButton.Enabled = $false
    $cf_actionButton.add_click( {
        $cf_itemsCount = $cf_SoftpaqsList.SelectedItems.count
        $cf_Categories = @()
        if ( $cf_CategoryBIOS.checked ) { $cf_Categories += 'BIOS'}
        if ( $cf_CategoryDriver.checked ) { $cf_Categories += 'Driver'}
        if ( $cf_CategorySoftware.checked ) { $cf_Categories += 'Software'}
        if ( $cf_CategoryFirmware.checked ) { $cf_Categories += 'Firmware'}
        if ( $cf_CategoryDock.checked ) { $cf_Categories += 'Dock'}

        if ( $cf_actionButton.Text -eq "Remove" ) {
            if ( (Remove_Solution $cf_SoftpaqsList $cf_Categories $cf_SolutionSearch.Text) ) { # remove all selected items in list
                if ( $cf_itemsCount -eq 1 ) {
                    $cf_actionMsg.Text = $cf_SoftpaqField.Text+': '+'Removed'
                } else {
                    $cf_actionMsg.Text = 'Multiple Softpaqs removed. Select one at a time to Replace'
                }
                $cf_RefFileMsg.Text = "Reference File updated"
            } else {
                $cf_actionMsg.Text = "Action can not be taken. Use Replacement if possible"
            }   
        } else {
            if ( $cf_SoftpaqField.Text -match 'MyHP') {
                $cf_actionMsg.Text = 'Due to complexity of MyHP, not able to Replace currently'
            } else {
                $cf_ReplaceResult = Replace_Solution $cf_SoftpaqsList $cf_SoftpaqField.Text $cf_SoftpaqReplace.Text $cf_Categories $cf_SolutionSearch.Text
                $cf_actionMsg.Text = $cf_SoftpaqField.Text+': '+'Replaced with '+': '+$cf_SoftpaqReplace.Text
                $cf_RefFileMsg.Text = "Reference File updated"
            }
        } # else if ( $cf_actionButton.Text -eq "Remove" )

        $cf_ssList.Items.Clear()
        $cf_SoftpaqField.Text = ""
        $cf_SoftpaqReplace.Text = ""
        $cf_actionButton.Enabled = $false
        
    } ) # $cf_actionButton.add_click

    # Add results text field
    $cf_actionMsg = New-Object System.Windows.Forms.Label
    $cf_actionMsg.ForeColor = 'blue'
    $cf_actionMsg.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset+120))  # (from left, from top)
    $cf_actionMsg.Size = New-Object System.Drawing.Size(280,35)  # (width, height)

    $ReplaceGroupBox.Controls.AddRange(@($cf_SpqLabel,$cf_SoftpaqField,$cf_SpqReplaceLabel,$cf_SoftpaqReplace,$cf_actionButton,$cf_actionMsg))
    $SolutionGroupBox.Controls.AddRange(@($ReplaceGroupBox))
    #$cf_Form.Controls.Add($ReplaceGroupBox)
    
    $cf_Debug = New-Object System.Windows.Forms.CheckBox ;  $cf_Debug.Enabled = $true
    $cf_Debug.Text = 'Actions Log'
    #$cf_Debug.Location = New-Object System.Drawing.Point(($FormWidth*.85),($FormHeight*.77))
    $cf_Debug.Location = New-Object System.Drawing.Point(($LeftOffset+600),($TopOffset+30))
    $cf_Debug.Size = New-Object System.Drawing.Size(100,20)  # (width, height)
    #$cf_actionButton.Checked = $true
    $cf_Debug.add_click( {
        if ( $cf_Debug.checked ) { 
            $Script:DebugInfo = $true 
            "ReferenceFile - $ReFileVersion - Script start at "+(Get-Date) | out-file $Script:LogFilePath
        } else { 
            $Script:DebugInfo = $false 
        }     
    }) # $cf_Form.add_click()
    $cf_Form.Controls.Add($cf_Debug)

    ###################################################################################
    # create group box to hold the Softpaq and replacement entries, and replace/remove button
    ###################################################################################
    $cf_RepoGroupBox = New-Object System.Windows.Forms.GroupBox
    $cf_RepoGroupBox.Text = 'Custom HPIA Offline Repository'
    $cf_RepoGroupBox.location = New-Object System.Drawing.Point(($LeftOffset),($TopOffset+420)) # (from left, from top)
    $cf_RepoGroupBox.Size = New-Object System.Drawing.Size(620,70)                    # (width, height)
    # add init_repo button
    $cf_GetRepoButton = New-Object System.Windows.Forms.Button
    $cf_GetRepoButton.Text = "Locate"
    $cf_GetRepoButton.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset))  # (from left, from top)
    $cf_GetRepoButton.AutoSize = $true
    $cf_GetRepoButton.Enabled = $true   
    $cf_GetRepoButton.Add_Click( {
        # initialize the repository for use by HPIA, return contains 'folder', 'message' entries
        $cf_SelectedFolder = Init_Repo $Script:CacheDir
        if ( $cf_SelectedFolder.Folder ) {
            $cf_RepoFolder.Text = $cf_SelectedFolder.Folder
            $cf_InitactionMsg.Text = $cf_SelectedFolder.Message
            $cf_SyncRepoButton.Enabled = $true             
        }
    } ) # $cf_GetRepoButton.Add_Click()
    # Add repo folder results text field
    $cf_InitactionMsg = New-Object System.Windows.Forms.Label
    $cf_InitactionMsg.ForeColor = 'blue'
    $cf_InitactionMsg.location = New-Object System.Drawing.Point(($LeftOffset-10),($TopOffset+20)) # (from left, from top)
    $cf_InitactionMsg.Size = New-Object System.Drawing.Size(360,20)  # (width, height)
    $cf_InitactionMsg.TextAlign = "BottomLeft"   
    # add repo populate button
    $cf_SyncRepoButton = New-Object System.Windows.Forms.Button
    $cf_SyncRepoButton.Text = "Sync"
    $cf_SyncRepoButton.location = New-Object System.Drawing.Point(($LeftOffset+500),($TopOffset))  # (from left, from top)
    $cf_SyncRepoButton.AutoSize = $true
    $cf_SyncRepoButton.Enabled = $false   
    $cf_SyncRepoButton.Add_Click( {
        if ( $cf_RepoFolder.Text.length -gt 0 ) {
            if ( $cf_SoftpaqsList.SelectedItems.count -gt 0 ) {
                if ( $Script:DebugInfo ) { "Sync started" | out-file -append $Script:LogFilePath }
                $cf_SaveCurrPath = Get-location
                $cf_refFileBasename = (Get-Item $cf_RefFilePath.Text).BaseName
                $cf_InitactionMsg.Text = "Sync for "+$cf_refFileBasename
                Set-location $cf_RepoFolder.Text
                if ( $Script:DebugInfo ) { "... Adding repository filter" | out-file -append $Script:LogFilePath }
                    # get the OS/OSver from reference file we are using
                    $cf_refFileBasename = (Get-Item $cf_RefFilePath.Text).BaseName
                    $cf_PlatformID = $cf_SelectedPlatform.Text.substring(0,4)
                    $cf_OS = "Win"+$cf_refFileBasename.split('_')[2].split('.')[0]
                    $cf_OSVer = $cf_refFileBasename.split('_')[2].split('.')[2]   
                Add-RepositoryFilter -platform $cf_PlatformID -OS $cf_OS -OSver $cf_OSVer -Category 'BIOS'
                $cf_InitactionMsg.Text = 'Invoking RepositorySync'
                if ( $Script:DebugInfo ) { "... Invoking RepositorySync to download required files" | out-file -append $Script:LogFilePath }
                Invoke-RepositorySync 6>&1
                if ( $Script:DebugInfo ) { "... Removing CMSL Sync'd files" | out-file -append $Script:LogFilePath }
                $cf_InitactionMsg.Text = 'Cleaning up after RepositorySync'
                Get-Childitem *.exe,*.cva,*.html -File -EA SilentlyContinue | Remove-Item
                if ( $Script:DebugInfo ) { "... Downloading Softpaqs" | out-file -append $Script:LogFilePath }
                $cf_XMLSolutions = $Script:xmlContent.SelectNodes("ImagePal/Solutions/UpdateInfo")
                foreach ( $item in $cf_SoftpaqsList.SelectedItems ) {
                    $cf_Spq = $item.Split(' ')[0]     # get softpaq # from entry picked
                    $cf_InitactionMsg.Text = "Downloading: '$cf_Spq' {exe, cva, html}"
                    if ( $Script:DebugInfo ) { $cf_InitactionMsg.Text | out-file -append $Script:LogFilePath }
                    Try {
                        $Error.Clear()
                        get-softpaq $cf_Spq 6>&1
                        get-softpaqmetadatafile $cf_Spq 6>&1
                        # handle html
                        $cf_htmlurl = ($cf_XMLSolutions | Where-Object { $_.id -eq $cf_Spq }).ReleaseNotesUrl
                        Invoke-WebRequest $cf_htmlurl -OutFile ".\$(Split-Path -Leaf $cf_htmlurl)"
                    } catch {
                        write-host $error[0].exception 
                    }
                } # foreach ( $item in $cf_SoftpaqsList.SelectedItems )
                Set-location $cf_SaveCurrPath
                $cf_InitactionMsg.Text = "Sync completed"
                if ( $Script:DebugInfo ) { "Sync completed" | out-file -append $Script:LogFilePath }
            } else {
                $cf_InitactionMsg.Text = 'No Solutions selected'
            } # else if ( $cf_SoftpaqsList.SelectedItems.count -gt 0 )
        } else {
            $cf_InitactionMsg.Text = "No Repository selected"
        } # if ( $cf_RepoFolder.Text.length -gt 0 )
    } )
    # add repo folder entry
    $cf_RepoFolder = New-Object System.Windows.Forms.TextBox
    $cf_RepoFolder.location = New-Object System.Drawing.Point(($LeftOffset+80),($TopOffset))  # (from left, from top)
    $cf_RepoFolder.Size = New-Object System.Drawing.Size(400,20)  # (width, height)
    $cf_RepoFolder.BorderStyle = 'FixedSingle'                # Options: Fixed3D, FixedSingle, None (default)
    
    $cf_RepoGroupBox.Controls.AddRange(@($cf_GetRepoButton,$cf_InitactionMsg,$cf_SyncRepoButton,$cf_RepoFolder))
    $cf_Form.Controls.Add($cf_RepoGroupBox)

    # Add 'file path label' label
    $cf_RefFilePathLbl = New-Object System.Windows.Forms.Label
    $cf_RefFilePathLbl.location = New-Object System.Drawing.Point(($LeftOffset+10),($TopOffset+510))  # (from left, from top)
    $cf_RefFilePathLbl.AutoSize = $true
    $cf_RefFilePathLbl.Text = "Reference File:"
    # Add 'working reference file path' data field
    $cf_RefFilePath = New-Object System.Windows.Forms.TextBox
    #$cf_RefFilePath.location = New-Object System.Drawing.Point(($LeftOffset+280),($TopOffset+40))  # (from left, from top)
    $cf_RefFilePath.location = New-Object System.Drawing.Point(($LeftOffset+100),($TopOffset+510))  # (from left, from top)
    $cf_RefFilePath.Size = New-Object System.Drawing.Size(520,30)  # (width, height)
    $cf_RefFilePath.BorderStyle = 'FixedSingle'                # Options: Fixed3D, FixedSingle, None (default)
    $cf_RefFilePath.Text = '.. working file ..'
    $cf_RefFilePath.ReadOnly = $true
    # Add 'file path message' label
    $cf_RefFileMsg = New-Object System.Windows.Forms.Label
    $cf_RefFileMsg.ForeColor = 'blue'
    $cf_RefFileMsg.location = New-Object System.Drawing.Point(($LeftOffset+10),($TopOffset+530))  # (from left, from top)
    $cf_RefFileMsg.Size = New-Object System.Drawing.Size(240,20)                      # (width, height)
    $cf_RefFileMsg.TextAlign = "BottomLeft"

    $cf_Form.Controls.AddRange(@($cf_RefFilePathLbl,$cf_RefFilePath,$cf_RefFileMsg))

    #----------------------------------------------------------------------------------
    # Create Done/Exit Button at the bottom of the dialog
    $cf_buttonDone = New-Object System.Windows.Forms.Button -Property `
        @{   # testing new method to set properties... kinda cool!!
            Location = New-Object System.Drawing.Point -Property @{ 
                X = ($FormWidth*.85) ; Y = ($FormHeight*.85) # position at 85% of the Form Width/Height
            }
            Text = 'Done'
        }
    $cf_buttonDone.add_click( { $cf_Form.Close() } ) # $cf_buttonDone.add_click
    $cf_Form.Controls.Add($cf_buttonDone)

    # Nothing appears until you show the Form
    $cf_Form.ShowDialog() | Out-Null

} # Function

Create_Form
