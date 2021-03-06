Add-Type -AssemblyName System.Windows.Forms 
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework

function Show-OpenFolderDialog
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [system.windows.Forms.TextBox]
        $txtBoxObj,
         
        [Parameter(Mandatory=$false, Position=1)]
        [Object]
        $InitialDirectory = "."
    )
     
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $InitialDirectory

    if ($dialog.ShowDialog() -eq "ok")
    {
        $txtBoxObj.text = $dialog.SelectedPath
    }
    else
    {
        #Throw 'Nothing selected.'   
    }
}

function Is-ValidFileFormat
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [System.String]
        $aFormatToCheck,
         
        [Parameter(Mandatory=$true, Position=1)]
        [System.String]
        $allowedFormatsList
    )

    #write-host "DEBUG: "$aFormatToCheck.ToLower()

    if($aFormatToCheck -ne "")
    {
        if($allowedFormatsList.Contains($aFormatToCheck.ToLower()))
        {
            return $true
        }
        else
        {
            return $false
        }
    }
    else
    {
        return $false
    }
}

function Populate-AContainerWithLabelsRefferencingImageFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [System.Windows.Forms.Control]
        $container,
         
        [Parameter(Mandatory=$true, Position=1)]
        [System.String]
        $pathToImages,
         
        [Parameter(Mandatory=$false, Position=2)]
        [System.String]
        $supportedExtensions = 'png,jpg,jpeg,bmp,gif,tif,tiff'
    )

    $status = test-path $pathToImages

    if ($status -ne $true)
    {
        [System.Windows.MessageBox]::Show('Error! The path defined in the variable "$pathToImages" is invalid! Please correct and run again.')
    }
    else
    {
        $leftValue = 2
        $topValueToStartFrom = 23
        $width = 1
        $height = 1
        $i = 0

        $currentTopValue = $topValueToStartFrom

        $maxTopValue = $container.Height
        $currentColumnMaxLeftValue = 0

        $topOffset = 33

        #remove recursion for now :(
        #$files = get-childitem -Recurse -File $pathToImages

        $files = get-childitem -File $pathToImages 

        #write-host "DEBUG: path to images: "$pathToImages

        #write-host "DEBUG: num of files found: "$files.Count

        if($files.Count -eq 0)
        {
            #[System.Windows.MessageBox]::Show("Error! Could not find any files. Please verify that files exist inside the path `"$pathToImages`" and run again.","Error","OK","Error")
        }
        else
        {
            foreach ($file in $files)
            {
                #write-host "DEBUG: "$file.name

                if (Is-ValidFileFormat ($file.extension.ToLower() -replace '\.','') $supportedExtensions)
                {
                    $label = New-Object System.Windows.Forms.Label

                    $picsLabelsArr.add($label)

                    $picsLabelsArr[$i].Name = "lblPics$i"
                    $picsLabelsArr[$i].Top = $currentTopValue
                    $picsLabelsArr[$i].Left = $leftValue
                    $picsLabelsArr[$i].autosize = $true
                    $picsLabelsArr[$i].BorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
                    $picsLabelsArr[$i].Font = "Microsoft Sans Serif,10"
                    $picsLabelsArr[$i].ForeColor = [System.Drawing.Color]::Black
                    $picsLabelsArr[$i].Tag = $file.fullname

                    $picsLabelsArr[$i].Text = $file.name

                    $picsLabelsArr[$i].Add_MouseDown({
                        $picsLabelsArr[$i].DoDragDrop($picsLabelsArr[$i].text, [System.Windows.Forms.DragDropEffects]::Copy)
                    }.GetNewClosure())

                    $picsLabelsArr[$i].Add_MouseMove({
                        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Hand
                    })

                    $picsLabelsArr[$i].Add_MouseEnter({
                        $global:fileCurrentlySelected = $file.fullname
                        $global:typeCurrentlySelected = "image"
                        $global:nameOfCurrentlySelected = "lblPics$i"
                        $global:indexOfCurrentlySelected = $i

                        #Write-Host "DEBUG: in 'Populate-AContainerWithLabelsRefferencingImageFiles': `$global:fileCurrentlySelected ="$global:fileCurrentlySelected
                        #Write-Host "DEBUG: in 'Populate-AContainerWithLabelsRefferencingImageFiles': `$file.fullname ="$file.fullname                      
                        #Write-Host "DEBUG: in 'Populate-AContainerWithLabelsRefferencingImageFiles': `$i ="$i
                        
                    }.GetNewClosure())

                    $picsLabelsArr[$i].Size = New-Object System.Drawing.Size($width,$height) 

                    $container.Controls.Add($picsLabelsArr[$i])

                    $currentTopValue = $currentTopValue + $topOffset
<#
                    if(($picsLabelsArr[$i].Left + $picsLabelsArr[$i].Width) > $currentColumnMaxLeftValue)
                    {
                        $currentColumnMaxLeftValue = $picsLabelsArr[$i].Left + $picsLabelsArr[$i].Width
                    }

                    if (($currentTopValue + $picsLabelsArr[$i].Height) -ge $maxTopValue)
                    {
                        $leftValue = $currentColumnMaxLeftValue + $leftOffset
                        $currentTopValue = $topValueToStartFrom
                    }

  #>                $i++

                     #write-host "DEBUG: finished processing file named '"$file.name"'."
                }
                else
                {
                    $numOfUnsupportedFiles++

                    #write-host "DEBUG: numOfUnsupportedFiles = $numOfUnsupportedFiles" 
                }

                if($numOfUnsupportedFiles -eq $numOfUnsupportedFilesMaxLimit)
                {
                    #write-host "DEBUG: Reached files processing limit. Aborting loop ..."

                    $numOfUnsupportedFiles = 0

                    break
                }
            }
        }
    }
}

function Populate-AContainerWithLabels
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [System.Windows.Forms.Control]
        $container,
         
        [Parameter(Mandatory=$true, Position=1)]
        [System.String]
        $numOfLabelsToCreate
    )
    
    $leftValue = 2
    $topValueToStartFrom = 1
    $width = 1
    $height = 1

    $currentTopValue = $topValueToStartFrom

    $topOffset = 33

    $i = 0

    $counter = 0
    
    while ($counter -lt $numOfLabelsToCreate)
    {
        $label = New-Object System.Windows.Forms.Label

        $reportLabelsArr.add($label)

        $reportLabelsArr[$i].Top = $currentTopValue
        $reportLabelsArr[$i].Left = $leftValue
        $reportLabelsArr[$i].autosize = $true
        $reportLabelsArr[$i].Tag = $i

        # init the selections array also because ps does not allow dynamic indexes creation
        $global:selectionsArr += ""

        $reportLabelsArr[$i].BorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
        $reportLabelsArr[$i].Font = "Microsoft Sans Serif,10"
        $reportLabelsArr[$i].ForeColor = [System.Drawing.Color]::Black

        $reportLabelsArr[$i].Text = "                                                                                "
        $reportLabelsArr[$i].AllowDrop = $true

        $label.Add_DragDrop({
            # self drag and drop request - replace 2 report items with each other
            if($global:typeCurrentlySelected -eq "picORrtf")
            {
                $draggedControlIndex = $global:indexOfCurrentlySelected
                $droppedControlIndex = $i

                # replace the controls inside the report array

                #$orgLabel = $reportLabelsArr[$droppedControlLabelsArrIndex]

                #$reportLabelsArr[$droppedControlLabelsArrIndex] = $reportLabelsArr[$draggedControlLabelsArrIndex]
                #$reportLabelsArr[$draggedControlLabelsArrIndex] = $orgLabel

                # replace the labels texts

                $droppedControlText = $label.Text
                
                $label.Text = $_.Data.GetData([System.Windows.Forms.DataFormats]::Text)

                $reportLabelsArr[$draggedControlIndex].text = $droppedControlText
                
                # replace the indexes in the selections array

                $draggedControlFileSpec = $global:selectionsArr[$draggedControlIndex]
                $droppedControlFileSpec = $global:selectionsArr[$droppedControlIndex]

                $global:selectionsArr[$droppedControlIndex] = $draggedControlFileSpec
                $global:selectionsArr[$draggedControlIndex] = $droppedControlFileSpec
            }
            else # a drag and drop request from one one the other panels was made
            {
                $label.Text = $_.Data.GetData([System.Windows.Forms.DataFormats]::Text)
                
                $global:selectionsArr[$label.Tag] = $global:fileCurrentlySelected

                if($global:nameOfCurrentlySelected -ne "")
                {
                    # remove the just used item from its respective panel
                    if ($global:typeCurrentlySelected -eq "image")
                    {
                        $panPics.Controls.RemoveByKey($global:nameOfCurrentlySelected)
                    }
                }

                #Write-Host "DEBUG: `$label.Tag ="$label.Tag
                #Write-Host "DEBUG: `$global:fileCurrentlySelected ="$global:fileCurrentlySelected
            }
        }.GetNewClosure())

        $label.Add_DragEnter({
           $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }.GetNewClosure())


        $label.Add_MouseDown({
            $label.DoDragDrop($reportLabelsArr[$i].text, [System.Windows.Forms.DragDropEffects]::Copy)
        }.GetNewClosure())

        $label.Add_MouseMove({
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Hand
        })

        $label.Add_MouseEnter({            
            $global:typeCurrentlySelected = "picORrtf"            
            $global:indexOfCurrentlySelected = $i
        }.GetNewClosure())


        $reportLabelsArr[$i].Size = New-Object System.Drawing.Size($width,$height) 

        $container.Controls.Add($reportLabelsArr[$i])

        $currentTopValue = $currentTopValue + $topOffset

        $counter++

        $i++
    }    
}

function Is-ArrayEmpty
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [System.Array]
        $arrToCheck
    )

    $i = 0

    while ($i -lt $arrToCheck.count)
    {
        if($arrToCheck[$i] -ne "")
        {
            return $false
        }

        $i++
    }
    
    return $true
}

function Generate-ReportInMSWord
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [System.Array]
        $templateFileToUse
    )

    add-type -AssemblyName Microsoft.Office.Interop.Word
    $wdunits = "Microsoft.Office.Interop.Word.wdunits" -as [type]

    $msWord = New-Object -Com Word.Application
    $msWord.visible = $true


    #$status = test-path $templateFileToUse

    #if($status -eq $true)
    #{
    #    $ptTemplate = $templateFileToUse
<#
        $docTemplate = $msWord.Documents.Open("$ptTemplate")

        $docTemplate.Activate()
 
        $filename = (Get-Random).ToString() + ".docx"

        $fileSpec = $reportSaveLocation + $filename

        $docTemplate.SaveAs($fileSpec)

        $docTemplate.Close()

        $docReport = $msWord.Documents.Open("$fileSpec")
#>
        #$docReport = $msWord.Documents.Add("$ptTemplate")
        
        $docReport = $msWord.Documents.Add("")
        
        <#$selection = $wordDoc.select($wordDoc.Sections.Last)         
          
        $selection.TypeParagraph()
        $selection.TypeText("this is a via code typed text...")

        #>

        for ($i=0; $i -lt $global:selectionsArr.count; $i++)
        {
            if($global:selectionsArr[$i] -ne "")
            {
                $img = [System.Drawing.Image]::Fromfile($global:selectionsArr[$i]);
                [System.Windows.Forms.Clipboard]::SetImage($img);                
                    
                #write-host "DEBUG: "$global:selectionsArr[$i]

                $range = $docReport.content 
                #$null = $range.moveend($wdunits::wdword,$range.end)

                #$range.endkey([Microsoft.Office.Interop.Word.wdunits]::wdStory)

                #$range.PasteAndFormat([Microsoft.Office.Interop.Word.WdRecoveryType]::wdUseDestinationStylesRecovery)

                # go to the end of the document
                $docReport.ActiveWindow.Selection.EndOf([Microsoft.Office.Interop.Word.wdunits]::wdStory)

                # paste the content from the clipboard
                $docReport.ActiveWindow.Selection.PasteAndFormat([Microsoft.Office.Interop.Word.WdRecoveryType]::wdUseDestinationStylesRecovery)

                # add a new line
                $docReport.ActiveWindow.Selection.TypeText("`n`n`n`n`n")

                # go to the end of the document
                #$wordDoc.Selection.EndKey([Microsoft.Office.Interop.Word]::wdStory)

                # paste the content from the clipboard
                #$wordDoc.Content.PasteAndFormat([Microsoft.Office.Interop.Word]::wdUseDestinationStylesRecovery)

                #$wordDoc.Close()
                #$msWord.Application.Quit()
            }
        }
    #}
    #else
    #{
    #    [System.Windows.MessageBox]::Show("Error! The given Word template file `"$templateFileToUse`" cannot be found! Aborting ...","Error","OK","Error")
    #}
}

function Generate-ReportInMSOutlook
{
    #create outlook Object
    $Outlook = New-Object -comObject Outlook.Application 

    $Mail = $Outlook.CreateItem(0)

    #$Mail.Recipients.Add("Myname@Mydomain.com") 

    $Mail.Subject = "Tutorial for " + $txtUserFilesPath.Text

    # save the signature
    $signature = $Mail.body
    
    # empty the letter
    $Mail.body = ""

    #write-host $global:selectionsArr.count
    
    # add the report items to the letter
    for ($i=0; $i -lt $global:selectionsArr.count; $i++)
    {
        if($global:selectionsArr[$i] -ne "")
        {
            $img = [System.Drawing.Image]::Fromfile($global:selectionsArr[$i]);
            [System.Windows.Forms.Clipboard]::SetImage($img);
            
            # get an editor object
            $wdDoc = $Mail.Getinspector.WordEditor
            $wdRange = $wdDoc.Range()
        
            # go to the end of the letter
            $endPosition = $wdRange.end() - 1
            $wdRange = $wdDoc.Range($endPosition, $endPosition)

            # paste content from the clipboard
            $wdRange.PasteAndFormat([Microsoft.Office.Interop.Word.WdRecoveryType]::wdUseDestinationStylesRecovery)

            # add a new line
            $wdRange.InsertAfter("`n`n`n`n`n")
        }
    }

    # go to the end of the letter
    $endPosition = $wdRange.end() - 1
    $wdRange = $wdDoc.Range($endPosition, $endPosition)

    # add the signature back
    $wdRange.InsertAfter($signature)

    # show the newly created letter
    $Mail.Display()
}

function Reset-ReportsPanel
{
    $panReport.Controls.Clear()

    $global:reportLabelsArr.Clear()
}

function Reset-PicsPanel
{
    $panPics.Controls.Clear()

    $global:picsLabelsArr.Clear()
}


##############################################
#
# Main Program
#
##############################################

#$FixingSuggestionsRtfsPrefix = "fix-"
$ptTemplateFileSpec = $PSScriptRoot + "\template\pt-report-template.docx"

#$reportSaveLocation = "C:\Windows\temp\"

$global:numOfUnsupportedFiles = 0
$global:numOfUnsupportedFilesMaxLimit = 50

$global:picsLabelsArr = New-Object System.Collections.ArrayList
$global:reportLabelsArr = New-Object System.Collections.ArrayList

$global:selectionsArr = @()
$global:fileCurrentlySelected = ""
$global:typeCurrentlySelected = "none"
$global:nameOfCurrentlySelected = ""
$global:indexOfCurrentlySelected = -1

$frmPtReports = New-Object System.Windows.Forms.Form

$frmPtReports.Text = "Tutorial Creator In Outlook v1.0" 
$frmPtReports.Size = New-Object System.Drawing.Size(1216,1000)

#$frmPtReports.AutoScale = $true
#$frmPtReports.AutoSize = $true
#$frmPtReports.AutoScroll = $true
    
$grpUserFiles = New-Object System.Windows.Forms.GroupBox

$grpUserFiles.Text = "User Files Location For Screenshots:"
$grpUserFiles.Font = "Microsoft Sans Serif,11,style=Bold"
$grpUserFiles.ForeColor = [System.Drawing.Color]::DodgerBlue
$grpUserFiles.Width = 1180
$grpUserFiles.Height = 60
$grpUserFiles.location = new-object system.drawing.point(10, 10) 

$frmPtReports.controls.Add($grpUserFiles)

$global:txtUserFilesPath = New-Object system.windows.Forms.TextBox
$txtUserFilesPath.Width = 1080
$txtUserFilesPath.Height = 23

$txtUserFilesPath.Text = ""
$txtUserFilesPath.AutoCompleteMode = 'SuggestAppend'
$txtUserFilesPath.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::FileSystemDirectories
#$txtUserFilesPath.Text = "C:\Users\ohadm\Desktop\tem"

$txtUserFilesPath.location = new-object system.drawing.point(20,20)
$txtUserFilesPath.Font = "Microsoft Sans Serif,10,style=Bold"

$txtUserFilesPath.Add_TextChanged({
    if ($txtUserFilesPath.Text -eq (Get-Clipboard))
    {
        $txtUserFilesPath.AutoCompleteMode = 'Append'
    }
    else
    {
        $txtUserFilesPath.AutoCompleteMode = 'SuggestAppend'
    }

    Reset-ReportsPanel
    Reset-PicsPanel

    if($txtUserFilesPath.Text -ne "")
    {
        $status = test-path $txtUserFilesPath.Text

        if($status -eq $true)
        {
            Populate-AContainerWithLabelsRefferencingImageFiles $panPics $txtUserFilesPath.Text            
            Populate-AContainerWithLabels $panReport $picsLabelsArr.Count

            if($btnGenerate.Enabled -eq $false)
            {
                $btnGenerate.Enabled = $true
            }

            if($btnReset.Enabled -eq $false)
            {
                $btnReset.Enabled = $true
            }
        }
    }
})

$grpUserFiles.controls.Add($txtUserFilesPath)

$btnBrowse = New-Object system.windows.Forms.Button
$btnBrowse.Text = "Browse"
$btnBrowse.Width = 70
$btnBrowse.Height = 25
#$btnBrowse.ForeColor = "#fbfbfb"
$btnBrowse.location = new-object system.drawing.point(($txtUserFilesPath.left + $txtUserFilesPath.width + 2), $txtUserFilesPath.top)
$btnBrowse.Font = "Microsoft Sans Serif,10"
$btnBrowse.ForeColor = [System.Drawing.Color]::Black

$btnBrowse.Add_Click({
    Show-OpenFolderDialog $txtUserFilesPath
})

$grpUserFiles.controls.Add($btnBrowse)

$global:grpPics = New-Object System.Windows.Forms.GroupBox

$grpPics.Text = "My Pictures Inventory (Drag zone):"
#$grpPics.AutoSize = $true
$grpPics.Font = "Microsoft Sans Serif,11,style=Bold"
$grpPics.ForeColor = [System.Drawing.Color]::DodgerBlue
$grpPics.Top = 72
$grpPics.Left = $grpUserFiles.Left
$grpPics.Anchor = "Left,Top" 
$grpPics.Size = New-Object System.Drawing.Size(558,440)

$global:panPics = New-Object System.Windows.Forms.Panel 
#$panPics.AutoSize = $true
$panPics.AutoScroll = $true
$panPics.Top = 20
$panPics.Left = 1
$panPics.Anchor = "Left,Top"
$panPics.Size = New-Object System.Drawing.Size(546,410)

$frmPtReports.Controls.Add($grpPics)

$grpPics.Controls.Add($panPics)


if($txtUserFilesPath.Text -ne "")
{
    Populate-AContainerWithLabelsRefferencingImageFiles $grpPics $txtUserFilesPath.Text
}

$grpReport = New-Object System.Windows.Forms.GroupBox 
$grpReport.Text = "Tutorial (Drop zone, Swap enabled):"
$grpReport.Font = "Microsoft Sans Serif,11,style=Bold"
$grpReport.ForeColor = [System.Drawing.Color]::DarkGreen
$grpReport.Top = 72
$grpReport.Left = 573
$grpReport.Anchor = "Left,Top"
$grpReport.Size = New-Object System.Drawing.Size(617,800)

$global:panReport = New-Object System.Windows.Forms.Panel 
#$panReport.AutoSize = $true
$panReport.AutoScroll = $true
$panReport.AllowDrop = $true
$panReport.Top = 20
$panReport.Left = 1
$panReport.Anchor = "Left,Top"
$panReport.Size = New-Object System.Drawing.Size(605,770)

$frmPtReports.Controls.Add($grpReport)

$grpReport.Controls.Add($panReport)


$grpOptions = New-Object System.Windows.Forms.GroupBox 
$grpOptions.Text = "Options:"
$grpOptions.AutoSize = $true
$grpOptions.Font = "Microsoft Sans Serif,11,style=Bold"
$grpOptions.ForeColor = [System.Drawing.Color]::CadetBlue
$grpOptions.Top = $grpReport.Top + $grpReport.Height
$grpOptions.Left = 573
$grpOptions.Anchor = "Left,Top"
$grpOptions.Size = New-Object System.Drawing.Size(309,40)


$radioOutlook = New-Object System.Windows.Forms.RadioButton 
#$radioOutlook.Location = '20,70'
#$radioOutlook.size = '350,20'
$radioOutlook.Checked = $true
$radioOutlook.AutoSize = $true
$radioOutlook.Text = "Generate in MS Outlook"
$radioOutlook.Left = 20
$radioOutlook.Top = 20
$radioOutlook.Font = "Microsoft Sans Serif,8"
$radioOutlook.ForeColor = [System.Drawing.Color]::Black

$radioWord = New-Object System.Windows.Forms.RadioButton 
#$radioWord.Location = '20,70'
#$radioWord.size = '350,20'
$radioWord.Checked = $false
$radioWord.AutoSize = $true
$radioWord.Text = "Generate in MS Word"
$radioWord.Left = 20
$radioWord.Top = $radioOutlook.Top + 20
$radioWord.Font = "Microsoft Sans Serif,8"
$radioWord.ForeColor = [System.Drawing.Color]::Black

#$grpOptions.Controls.AddRange(@($radioWord,$radioOutlook))

$frmPtReports.Controls.Add($grpOptions)

$grpOptions.Controls.Add($radioOutlook)
$grpOptions.Controls.Add($radioWord)


$grpActions = New-Object System.Windows.Forms.GroupBox 
$grpActions.Text = "Actions:"
$grpActions.AutoSize = $true
$grpActions.Font = "Microsoft Sans Serif,11,style=Bold"
$grpActions.ForeColor = [System.Drawing.Color]::CadetBlue
$grpActions.Top = $grpReport.Top + $grpReport.Height
$grpActions.Left = $grpOptions.Left + $grpOptions.Width + 2
$grpActions.Anchor = "Left,Top"
$grpActions.Size = New-Object System.Drawing.Size(308,80)

$btnGenerate = New-Object System.Windows.Forms.Button 
$btnGenerate.Text = "Generate"
$btnGenerate.Enabled = $false
$btnGenerate.AutoSize = $true
$btnGenerate.Width = 70
$btnGenerate.Height = 25
$btnGenerate.Font = "Microsoft Sans Serif,10"
$btnGenerate.ForeColor = [System.Drawing.Color]::Black
$btnGenerate.location = new-object system.drawing.point(20,20)

$btnGenerate.Add_Click({
    if(Is-ArrayEmpty $global:selectionsArr)
    {
        [System.Windows.MessageBox]::Show('Nothing to generate...No selections were made yet. Please select something first ...','Info','OK','Info')
    }
    else
    {
        $btnGenerate.Text = "Working..."
        $btnGenerate.Enabled = $false

        if($radioWord.Checked -eq $true)
        {
            Generate-ReportInMSWord $ptTemplateFileSpec
        }
        else
        {
            if($radioOutlook.Checked -eq $true)
            {
                Generate-ReportInMSOutlook
            }
        }

        $btnGenerate.Enabled = $true
        $btnGenerate.Text = "Generate"
    }
})

$grpActions.Controls.Add($btnGenerate)

$btnReset = New-Object System.Windows.Forms.Button 
$btnReset.Text = "Reset"
$btnReset.Enabled = $false
$btnReset.AutoSize = $true
$btnReset.Width = 70
$btnReset.Height = 25
$btnReset.Font = "Microsoft Sans Serif,10"
$btnReset.ForeColor = [System.Drawing.Color]::Black
$btnReset.location = new-object system.drawing.point(($btnGenerate.left + $btnGenerate.width + 8), $btnGenerate.top)

$btnReset.Add_Click({
    Reset-ReportsPanel
    Reset-PicsPanel

    $i = 0
    $len = $global:selectionsArr.count

    while($i -lt $len)
    {
        $global:selectionsArr[$i] = ""

        $i++
    }

    Populate-AContainerWithLabelsRefferencingImageFiles $panPics $txtUserFilesPath.Text
    Populate-AContainerWithLabels $panReport $picsLabelsArr.Count
})

$grpActions.Controls.Add($btnReset)

$btnExit = New-Object system.windows.Forms.Button
$btnExit.Text = "Exit Program"
$btnExit.AutoSize = $true
$btnExit.Width = 70
$btnExit.Height = 25
$btnExit.Font = "Microsoft Sans Serif,10"
$btnExit.ForeColor = [System.Drawing.Color]::Black
$btnExit.location = new-object system.drawing.point(($btnReset.left + $btnReset.width + 30), $btnReset.top)

$btnExit.Add_Click({
    $frmPtReports.Close()
})

$grpActions.controls.Add($btnExit)

$frmPtReports.Controls.Add($grpActions)

# move the form to a fixed location
$frmPtReports.StartPosition = "manual"
$frmPtReports.Location = New-Object System.Drawing.Size(100, 10)


$frmPtReports.ShowDialog()
