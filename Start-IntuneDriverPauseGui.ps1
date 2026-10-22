#requires -Version 5.1

<#
.SYNOPSIS
    Interface graphique pour la suspension et l'approbation de pilotes Intune.

.DESCRIPTION
    Permet de simuler ou d'executer le controle, d'approuver un pilote sur un
    profil ou tous les profils, d'installer la tache planifiee horaire et d'ouvrir
    le journal. Reutilise les scripts de catalogue, de controle et de planification.
#>

[CmdletBinding()]
param(
    [Parameter(DontShow = $true)]
    [switch] $ValidateOnly,

    [Parameter(DontShow = $true)]
    [switch] $AutomatedTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Cette interface WPF est disponible uniquement sous Windows.'
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $powerShellExecutable = (Get-Process -Id $PID).Path
    $relaunchArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ('"{0}"' -f $PSCommandPath)
    )
    if ($ValidateOnly) {
        $relaunchArguments += '-ValidateOnly'
    }
    if ($AutomatedTest) {
        $relaunchArguments += '-AutomatedTest'
    }

    Start-Process `
        -FilePath $powerShellExecutable `
        -ArgumentList $relaunchArguments | Out-Null
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$watchScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Watch-IntuneDriverPause.ps1'
$registerScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Register-IntuneDriverPauseScheduledTask.ps1'
$catalogScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-IntuneDriverPauseCatalog.ps1'
$settingsPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'IntuneDriverPause\GuiSettings.json'
$defaultLogPath = Join-Path -Path $env:ProgramData -ChildPath 'IntuneDriverPause\Logs\IntuneDriverPause.log'
$powerShellExecutable = (Get-Process -Id $PID).Path

foreach ($requiredScript in @($watchScriptPath, $registerScriptPath, $catalogScriptPath)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Script requis introuvable : $requiredScript"
    }
}

function ConvertTo-PowerShellStringLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    return "'{0}'" -f $Value.Replace("'", "''")
}

function ConvertTo-PowerShellArrayLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Value
    )

    $items = @($Value | ForEach-Object { ConvertTo-PowerShellStringLiteral -Value $_ })
    return '@({0})' -f ($items -join ',')
}

function ConvertFrom-MultilineText {
    param(
        [AllowEmptyString()]
        [string] $Value
    )

    return @(
        $Value -split '\r?\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Intune Driver Pause"
    Width="1100"
    Height="980"
    MinWidth="940"
    MinHeight="760"
    WindowStartupLocation="CenterScreen"
    Background="#F4F7FB"
    FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TextBox">
            <Setter Property="MinHeight" Value="30"/>
            <Setter Property="Padding" Value="7,4"/>
            <Setter Property="BorderBrush" Value="#B8C4D4"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="White"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="MinHeight" Value="30"/>
            <Setter Property="Padding" Value="7,4"/>
            <Setter Property="BorderBrush" Value="#B8C4D4"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Background" Value="White"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="MinHeight" Value="30"/>
            <Setter Property="Padding" Value="5,3"/>
            <Setter Property="BorderBrush" Value="#B8C4D4"/>
            <Setter Property="Background" Value="White"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="MinHeight" Value="34"/>
            <Setter Property="Padding" Value="15,5"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Background" Value="#E7EDF5"/>
            <Setter Property="BorderBrush" Value="#B8C4D4"/>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#0F6CBD"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#0F6CBD"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#C42B1C"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#C42B1C"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Margin" Value="0,0,0,12"/>
            <Setter Property="Padding" Value="12"/>
            <Setter Property="BorderBrush" Value="#D7E0EB"/>
            <Setter Property="Background" Value="White"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Padding" Value="0,5,8,5"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Foreground" Value="#243447"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#102A43" Padding="22,16">
            <StackPanel>
                <TextBlock Text="Intune Driver Pause" Foreground="White" FontSize="24" FontWeight="SemiBold"/>
                <TextBlock
                    Margin="0,4,0,0"
                    Text="Interception ciblée d'un pilote dans les profils Windows Driver Update"
                    Foreground="#C8D8E8"
                    FontSize="13"/>
            </StackPanel>
        </Border>

        <TabControl Grid.Row="1" Margin="12,10,12,0">
            <TabItem Header="Actions sur les drivers">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="6,12,6,0">
                    <StackPanel>
                <GroupBox Header="1. Connexion Microsoft Graph">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="170"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="170"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Label Grid.Row="0" Grid.Column="0" Content="Mode *"/>
                        <ComboBox x:Name="AuthenticationModeComboBox" Grid.Row="0" Grid.Column="1" SelectedIndex="0">
                            <ComboBoxItem Content="Compte utilisateur (interactif)" Tag="Interactive"/>
                            <ComboBoxItem Content="Secret client" Tag="ClientSecret"/>
                            <ComboBoxItem Content="Certificat" Tag="Certificate"/>
                        </ComboBox>

                        <Label x:Name="TenantIdLabel" Grid.Row="0" Grid.Column="2" Content="Tenant ID (optionnel)"/>
                        <TextBox x:Name="TenantIdTextBox" Grid.Row="0" Grid.Column="3"/>

                        <Label Grid.Row="1" Grid.Column="0" Content="Application ID"/>
                        <TextBox x:Name="ClientIdTextBox" Grid.Row="1" Grid.Column="1"/>

                        <Label Grid.Row="1" Grid.Column="2" Content="Valeur du secret"/>
                        <PasswordBox
                            x:Name="ClientSecretPasswordBox"
                            Grid.Row="1"
                            Grid.Column="3"
                            ToolTip="Saisissez la valeur du secret client, et non son identifiant."/>

                        <Label Grid.Row="2" Grid.Column="0" Content="Certificat machine"/>
                        <ComboBox
                            x:Name="CertificateComboBox"
                            Grid.Row="2"
                            Grid.Column="1"
                            Grid.ColumnSpan="2"
                            DisplayMemberPath="Label"
                            SelectedValuePath="Thumbprint"/>
                        <Button
                            x:Name="RefreshCertificatesButton"
                            Grid.Row="2"
                            Grid.Column="3"
                            Margin="8,0,0,0"
                            Content="Actualiser les certificats"/>

                        <StackPanel Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" Margin="0,10,0,0">
                            <Button
                                x:Name="LoadProfilesButton"
                                Content="Se connecter et lister les profils"
                                Style="{StaticResource PrimaryButton}"/>
                            <TextBlock
                                x:Name="ConnectionStatusTextBlock"
                                Margin="8,0,0,0"
                                VerticalAlignment="Center"
                                Foreground="#52677D"
                                Text="Non connecté"/>
                        </StackPanel>
                    </Grid>
                </GroupBox>

                <GroupBox Header="2. Profils WUfB Drivers existants">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
                            <Button
                                x:Name="RefreshCatalogButton"
                                Content="Actualiser profils et drivers"
                                ToolTip="Recharge le catalogue avec la session active."/>
                        </StackPanel>
                        <DataGrid
                            x:Name="ProfilesDataGrid"
                            Grid.Row="1"
                            Height="160"
                            AutoGenerateColumns="False"
                            IsReadOnly="True"
                            SelectionMode="Single"
                            SelectionUnit="FullRow"
                            CanUserAddRows="False"
                            HeadersVisibility="Column"
                            GridLinesVisibility="Horizontal">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Nom du profil" Binding="{Binding displayName}" Width="*"/>
                                <DataGridTextColumn Header="Approbation" Binding="{Binding approvalType}" Width="120"/>
                                <DataGridTextColumn Header="Nouveaux drivers" Binding="{Binding newUpdates}" Width="120"/>
                                <DataGridTextColumn Header="Appareils" Binding="{Binding deviceReporting}" Width="90"/>
                                <DataGridTextColumn Header="Identifiant" Binding="{Binding id}" Width="250"/>
                            </DataGrid.Columns>
                        </DataGrid>
                    </Grid>
                </GroupBox>

                <GroupBox Header="3. Drivers du profil source sélectionné">
                    <DataGrid
                        x:Name="DriversDataGrid"
                        Height="230"
                        AutoGenerateColumns="False"
                        IsReadOnly="True"
                        SelectionMode="Single"
                        SelectionUnit="FullRow"
                        CanUserAddRows="False"
                        HeadersVisibility="Column"
                        GridLinesVisibility="Horizontal">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Nom" Binding="{Binding name}" Width="2*"/>
                            <DataGridTextColumn Header="Version" Binding="{Binding version}" Width="130"/>
                            <DataGridTextColumn Header="Fabricant" Binding="{Binding manufacturer}" Width="160"/>
                            <DataGridTextColumn Header="État" Binding="{Binding approvalStatus}" Width="100"/>
                            <DataGridTextColumn Header="Catégorie" Binding="{Binding category}" Width="120"/>
                            <DataGridTextColumn Header="Appareils" Binding="{Binding applicableDeviceCount}" Width="80"/>
                            <DataGridTextColumn Header="Identifiant" Binding="{Binding id}" Width="250"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </GroupBox>

                <GroupBox Header="4. Driver à mettre en pause dans tous les profils">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="170"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="170"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Label Grid.Row="0" Grid.Column="0" Content="Mode de sélection"/>
                        <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal">
                            <RadioButton
                                x:Name="UseSelectedDriverRadioButton"
                                Content="Driver sélectionné"
                                IsChecked="True"
                                Margin="0,0,18,0"
                                VerticalAlignment="Center"/>
                            <RadioButton
                                x:Name="UseManualDriverRadioButton"
                                Content="Saisie manuelle"
                                VerticalAlignment="Center"/>
                        </StackPanel>

                        <Label Grid.Row="0" Grid.Column="2" Content="Profil source"/>
                        <TextBlock
                            x:Name="SelectedProfileTextBlock"
                            Grid.Row="0"
                            Grid.Column="3"
                            VerticalAlignment="Center"
                            Foreground="#52677D"
                            Text="Aucun"/>

                        <Label Grid.Row="1" Grid.Column="0" Content="Driver sélectionné"/>
                        <TextBox
                            x:Name="SelectedDriverTextBox"
                            Grid.Row="1"
                            Grid.Column="1"
                            Grid.ColumnSpan="3"
                            IsReadOnly="True"
                            Background="#EEF3F8"/>

                        <Label Grid.Row="2" Grid.Column="0" Content="Nom(s) manuel(s)"/>
                        <TextBox
                            x:Name="DriverNameTextBox"
                            Grid.Row="2"
                            Grid.Column="1"
                            Height="54"
                            AcceptsReturn="True"
                            VerticalContentAlignment="Top"
                            ToolTip="Un nom par ligne."/>

                        <Label Grid.Row="2" Grid.Column="2" Content="Correspondance"/>
                        <ComboBox x:Name="MatchModeComboBox" Grid.Row="2" Grid.Column="3" SelectedIndex="0">
                            <ComboBoxItem Content="Exact"/>
                            <ComboBoxItem Content="Contains"/>
                            <ComboBoxItem Content="Wildcard"/>
                        </ComboBox>

                        <Label Grid.Row="3" Grid.Column="0" Content="Fabricant exact"/>
                        <TextBox x:Name="ManufacturerTextBox" Grid.Row="3" Grid.Column="1"/>

                        <Label Grid.Row="3" Grid.Column="2" Content="Version exacte"/>
                        <TextBox x:Name="VersionTextBox" Grid.Row="3" Grid.Column="3"/>

                        <Label Grid.Row="4" Grid.Column="0" Content="Nom de la tâche"/>
                        <TextBox x:Name="TaskNameTextBox" Grid.Row="4" Grid.Column="1" Text="Intune - Suspension pilote cible"/>

                        <Label Grid.Row="4" Grid.Column="2" Content="Exécution élevée"/>
                        <TextBlock
                            x:Name="ElevationStatusTextBlock"
                            Grid.Row="4"
                            Grid.Column="3"
                            VerticalAlignment="Center"
                            Foreground="#52677D"/>

                        <Label Grid.Row="5" Grid.Column="0" Content="Fichier journal"/>
                        <TextBox x:Name="LogPathTextBox" Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="3"/>
                    </Grid>
                </GroupBox>

                <StackPanel Orientation="Horizontal" Margin="0,2,0,12">
                    <Button x:Name="SimulationButton" Content="Simuler" Style="{StaticResource PrimaryButton}"/>
                    <Button x:Name="ExecuteButton" Content="Suspendre sur tous les profils" Style="{StaticResource DangerButton}"/>
                    <Button x:Name="InstallTaskButton" Content="Installer la tâche horaire"/>
                    <Button x:Name="OpenLogButton" Content="Ouvrir le journal"/>
                </StackPanel>

                <WrapPanel Margin="0,0,0,12">
                    <Button x:Name="ApproveProfileButton" Content="Approuver sur le profil sélectionné"/>
                    <Button x:Name="ApproveAllButton" Content="Approuver sur tous les profils"/>
                </WrapPanel>

                <Border Background="#FFF4CE" BorderBrush="#E6C664" BorderThickness="1" Padding="10" Margin="0,0,0,12">
                    <TextBlock
                        TextWrapping="Wrap"
                        Foreground="#5C4B00"
                        Text="Conseil : commencez par Simuler. Le secret n'est jamais enregistré. La tâche horaire exige le mode Certificat et peut déclencher une demande UAC."/>
                </Border>

                <GroupBox Header="Résultat">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <ProgressBar
                            x:Name="ActivityProgressBar"
                            Grid.Row="0"
                            Height="4"
                            Margin="0,0,0,8"
                            IsIndeterminate="True"
                            Visibility="Collapsed"/>
                        <TextBox
                            x:Name="OutputTextBox"
                            Grid.Row="1"
                            Height="190"
                            IsReadOnly="True"
                            AcceptsReturn="True"
                            VerticalContentAlignment="Top"
                            VerticalScrollBarVisibility="Auto"
                            HorizontalScrollBarVisibility="Auto"
                            FontFamily="Consolas"
                            FontSize="12"
                            Background="#0D1B2A"
                            Foreground="#D9E7F5"
                            BorderBrush="#0D1B2A"/>
                    </Grid>
                </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="Profils du driver">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel Grid.Row="0" Margin="0,0,0,12">
                        <TextBlock
                            Text="Profils contenant le driver choisi"
                            FontSize="18"
                            FontWeight="SemiBold"
                            Foreground="#243447"/>
                        <TextBlock
                            Margin="0,5,0,0"
                            Foreground="#52677D"
                            TextWrapping="Wrap"
                            Text="Choisissez un driver du catalogue complet pour retrouver tous les profils où il est présent, quel que soit son état. La sélection dans Actions sur les drivers est également reprise ici."/>
                    </StackPanel>
                    <Grid Grid.Row="1" Margin="0,0,0,12">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Label Grid.Column="0" Content="Driver"/>
                        <ComboBox
                            x:Name="DriverProfilesComboBox"
                            Grid.Column="1"
                            DisplayMemberPath="Label"
                            SelectedValuePath="DriverId"
                            IsTextSearchEnabled="True"
                            TextSearch.TextPath="Label"
                            ToolTip="Nom, version, fabricant et identifiant Graph du driver."/>
                    </Grid>
                    <DataGrid
                        x:Name="DriverProfilesDataGrid"
                        Grid.Row="2"
                        AutoGenerateColumns="False"
                        IsReadOnly="True"
                        SelectionMode="Single"
                        SelectionUnit="FullRow"
                        CanUserAddRows="False"
                        HeadersVisibility="Column"
                        GridLinesVisibility="Horizontal">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Nom du profil" Binding="{Binding ProfileName}" Width="2*"/>
                            <DataGridTextColumn Header="Approbation du profil" Binding="{Binding ApprovalType}" Width="160"/>
                            <DataGridTextColumn Header="État du driver" Binding="{Binding ApprovalStatus}" Width="140"/>
                            <DataGridTextColumn Header="Identifiant du profil" Binding="{Binding ProfileId}" Width="2*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <DockPanel Grid.Row="3" Margin="0,10,0,0" LastChildFill="True">
                        <Button
                            x:Name="RefreshDriverProfilesButton"
                            Content="Actualiser profils et drivers"
                            DockPanel.Dock="Right"
                            Margin="8,0,0,0"/>
                        <TextBlock
                            x:Name="DriverProfilesStatusTextBlock"
                            Text="Connectez-vous pour charger les profils et drivers."
                            VerticalAlignment="Center"
                            Foreground="#52677D"/>
                    </DockPanel>
                </Grid>
            </TabItem>

            <TabItem Header="Suivi des drivers en pause">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Margin="0,0,0,10">
                        <TextBlock
                            FontSize="18"
                            FontWeight="SemiBold"
                            Foreground="#243447"
                            Text="Drivers actuellement en pause"/>
                        <TextBlock
                            Margin="0,5,0,0"
                            Foreground="#52677D"
                            TextWrapping="Wrap"
                            Text="Cette vue regroupe chaque driver suspendu et tous les profils dans lesquels il est présent. Une ligne jaune signale un nouveau profil, ou une suspension incomplète, à traiter."/>
                    </StackPanel>

                    <DataGrid
                        x:Name="PausedDriversDataGrid"
                        Grid.Row="1"
                        AutoGenerateColumns="False"
                        IsReadOnly="True"
                        SelectionMode="Single"
                        SelectionUnit="FullRow"
                        CanUserAddRows="False"
                        HeadersVisibility="Column"
                        GridLinesVisibility="Horizontal">
                        <DataGrid.RowStyle>
                            <Style TargetType="DataGridRow">
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding NeedsCompletion}" Value="True">
                                        <Setter Property="Background" Value="#FFF4CE"/>
                                        <Setter Property="ToolTip" Value="Ce driver n'est pas encore suspendu dans tous les profils où il est présent."/>
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </DataGrid.RowStyle>
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Nom du driver" Binding="{Binding Name}" Width="2*"/>
                            <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="115"/>
                            <DataGridTextColumn Header="Fabricant" Binding="{Binding Manufacturer}" Width="140"/>
                            <DataGridTemplateColumn Header="Profils où le driver est présent" Width="2*">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock
                                            Margin="4"
                                            Text="{Binding AllProfiles}"
                                            TextWrapping="Wrap"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTemplateColumn Header="Profils à compléter" Width="2*">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock
                                            Margin="4"
                                            Text="{Binding MissingProfiles}"
                                            TextWrapping="Wrap"
                                            Foreground="#9D5D00"
                                            FontWeight="SemiBold"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="État" Binding="{Binding Status}" Width="110"/>
                        </DataGrid.Columns>
                    </DataGrid>

                    <Grid Grid.Row="2" Margin="0,10,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock
                                x:Name="PausedDriversStatusTextBlock"
                                Foreground="#52677D"
                                VerticalAlignment="Center"
                                Text="Connectez-vous pour charger les suspensions."/>
                            <TextBlock
                                Margin="0,3,0,0"
                                Foreground="#9D5D00"
                                Text="Jaune = au moins un profil reste à suspendre."/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                            <Button
                                x:Name="RefreshPausedDriversButton"
                                Content="Actualiser la vue"/>
                            <Button
                                x:Name="CompletePauseButton"
                                Content="Compléter la pause"
                                Style="{StaticResource DangerButton}"
                                IsEnabled="False"/>
                        </StackPanel>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem x:Name="HelpTabItem" Header="Aide">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="12">
                    <StackPanel x:Name="HelpContentPanel">
                        <TextBlock
                            Text="Guide d'utilisation"
                            FontSize="20"
                            FontWeight="SemiBold"
                            Foreground="#243447"
                            Margin="0,0,0,12"/>
                        <GroupBox Header="1. Prérequis">
                            <StackPanel>
                                <TextBlock TextWrapping="Wrap"
                                    Text="Utilisez Windows avec PowerShell et WPF, un accès réseau à Microsoft Graph et une licence Intune active. Conservez tous les scripts dans le même dossier. Installez le module Microsoft.Graph.Authentication avant de lancer l'application."/>
                                <TextBlock Margin="0,8,0,8" FontFamily="Consolas" TextWrapping="Wrap"
                                    Text="Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"/>
                                <TextBlock TextWrapping="Wrap"
                                    Text="Pour une tâche exécutée par SYSTEM, installez le module avec -Scope AllUsers depuis une console élevée. Lancez ensuite Start-IntuneDriverPauseGui.ps1. Les appels Intune utilisent l'API Microsoft Graph beta."/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="2. Permissions et connexion Microsoft Graph">
                            <StackPanel>
                                <TextBlock TextWrapping="Wrap"
                                    Text="Compte utilisateur : autorisez la permission déléguée DeviceManagementConfiguration.ReadWrite.All ; le compte doit aussi posséder les droits Intune nécessaires. Le Tenant ID est facultatif. Cliquez sur Se connecter et lister les profils et terminez la connexion Microsoft, y compris la MFA si elle est demandée."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="Secret client : fournissez le Tenant ID, l'Application ID et la valeur du secret (pas son identifiant). L'application Entra ID doit disposer de la permission Application DeviceManagementConfiguration.ReadWrite.All avec consentement administrateur."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="Certificat : utilisez les mêmes permissions applicatives, ajoutez le certificat à l'application Entra ID et installez-le avec sa clé privée dans Cert:\LocalMachine\My. Renseignez le Tenant ID et l'Application ID, puis sélectionnez le certificat."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="La connexion est conservée en mémoire pendant l'ouverture de l'application et réutilisée pour les actualisations, simulations, suspensions et approbations. Un changement du mode, du tenant, de l'application ou du certificat ferme la session précédente. Les paramètres de connexion sont verrouillés pendant une opération. Une stratégie Entra ID, une révocation ou une expiration nécessitant une interaction peut imposer une nouvelle authentification."/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="3. Choisir un driver et simuler">
                            <StackPanel>
                                <TextBlock TextWrapping="Wrap"
                                    Text="Dans Actions sur les drivers, connectez-vous puis sélectionnez un profil source et un driver dans son inventaire. Le ciblage utilise son identifiant Graph pour éviter les homonymes. Commencez par Simuler : aucune modification n'est appliquée."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="En Saisie manuelle, entrez un nom par ligne. Exact compare le nom complet ; Contains recherche une partie du nom ; Wildcard accepte les caractères génériques, comme *. Les filtres Fabricant exact et Version exacte limitent la recherche. Les modes partiels peuvent cibler plusieurs drivers : vérifiez toujours la simulation et le journal."/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="4. Suspendre ou approuver : bien vérifier le périmètre">
                            <StackPanel>
                                <TextBlock TextWrapping="Wrap"
                                    Text="Simuler et Suspendre sur tous les profils analysent tous les profils WUfB Drivers, pas uniquement le profil source. Un driver absent est ignoré ; un driver déjà suspendu n'est pas modifié. Seul un driver approved peut être suspendu. Un driver needsReview n'est pas encore autorisé au déploiement et ne peut pas être suspendu ; declined n'est pas suspendable non plus. Ces états sont signalés comme des erreurs détaillées, sans approbation automatique. Les drivers approuvés restent traités, même si d'autres sont refusés. La suspension est confirmée par relecture de l'inventaire."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="Approuver sur le profil sélectionné ne cible que le profil source. Approuver sur tous les profils cible chaque profil où le driver est présent. Ces boutons exigent un driver sélectionné dans la liste (pas une saisie manuelle) et la permission d'écriture. Une confirmation précède l'approbation pour un déploiement immédiat ; l'état approved est ensuite vérifié."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap" Foreground="#9D5D00"
                                    Text="Attention : approuver un driver ne désactive pas sa tâche horaire de suspension. Si cette tâche le cible, elle pourra le suspendre à nouveau. Désactivez-la ou adaptez-la dans le Planificateur de tâches Windows pour conserver l'approbation."/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="5. Retrouver tous les profils d'un driver">
                            <TextBlock TextWrapping="Wrap"
                                Text="Dans Profils du driver, choisissez un driver dans le catalogue complet. Le nom, la version, le fabricant et l'identifiant Graph permettent de le distinguer. La grille affiche chaque profil contenant ce driver, son mode d'approbation et l'état du driver. La sélection effectuée dans Actions sur les drivers est reprise ici. Choisir un autre driver dans cet onglet de consultation ne change pas la cible des actions. Cette vue fonctionne aussi en lecture seule."/>
                        </GroupBox>
                        <GroupBox Header="6. Suivre et compléter les suspensions">
                            <TextBlock TextWrapping="Wrap"
                                Text="Suivi des drivers en pause regroupe les drivers suspendus et les profils où ils sont présents. Une ligne jaune indique qu'au moins un profil reste à suspendre. Sélectionnez la ligne puis Compléter la pause pour ne traiter que les profils manquants. Actualiser la vue ou Actualiser profils et drivers recharge le catalogue avec la connexion active. Actualisez pour voir les modifications externes, les nouveaux profils ou le résultat d'une suspension par saisie manuelle ; choisissez ensuite à nouveau le driver."/>
                        </GroupBox>
                        <GroupBox Header="7. Installer la tâche horaire">
                            <TextBlock TextWrapping="Wrap"
                                Text="La tâche horaire exige le mode Certificat, le module Graph accessible à SYSTEM et un certificat avec clé privée dans LocalMachine\My. SYSTEM doit pouvoir lire la clé privée. Définissez le nom de la tâche et le chemin du journal, simulez, puis cliquez sur Installer la tâche horaire. Acceptez l'élévation UAC si nécessaire. La tâche est créée ou remplacée, s'exécute toutes les heures sous SYSTEM et analyse tous les profils, y compris ceux créés ultérieurement. Elle continue après la fermeture de l'application. Les modes utilisateur et secret client ne sont pas pris en charge pour cette tâche."/>
                        </GroupBox>
                        <GroupBox Header="8. Résultats, journal et dépannage">
                            <StackPanel>
                                <TextBlock TextWrapping="Wrap"
                                    Text="Consultez Résultat dans Actions sur les drivers, puis Ouvrir le journal. Le chemin par défaut est %ProgramData%\IntuneDriverPause\Logs\IntuneDriverPause.log. La rotation conserve cinq archives après une taille de 10 Mo. Un refus individuel Graph entraîne une attente et une relecture ; seuls les pilotes encore concernés sont retentés, avec un maximum de trois appels et uniquement si leur état reste compatible. Un refus persistant reste une erreur. Une erreur sur un profil ne bloque pas le traitement des autres profils, mais fait échouer l'opération globale : actualisez le catalogue avant de réessayer."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="Boutons désactivés : vérifiez la connexion, le profil source, la sélection du driver et les droits d'écriture. Avec un secret client sans DeviceManagementConfiguration.ReadWrite.All, la lecture et la simulation restent disponibles, mais pas les modifications. Vérifiez la permission Application et le consentement administrateur."/>
                                <TextBlock Margin="0,8,0,0" TextWrapping="Wrap"
                                    Text="Erreur d'authentification : vérifiez le tenant, l'application, l'expiration du secret ou du certificat et les règles d'accès conditionnel. Pour changer de compte utilisateur, fermez puis relancez l'application. Certificat absent : vérifiez LocalMachine\My, la présence de la clé privée et ses droits d'accès. Profil ou driver absent : rechargez le catalogue et vérifiez les filtres. État non confirmé ou échec partiel : consultez le journal et actualisez avant toute nouvelle action."/>
                            </StackPanel>
                        </GroupBox>
                        <GroupBox Header="9. Confidentialité et fermeture">
                            <TextBlock TextWrapping="Wrap"
                                Text="Aucun secret, jeton ou clé privée n'est enregistré par l'interface sur disque. Le secret client est conservé sous forme de SecureString en mémoire et transmis à l'espace d'exécution sans être inscrit dans la commande. Les réglages non sensibles sont mémorisés dans %LOCALAPPDATA%\IntuneDriverPause\GuiSettings.json. Attendez la fin de l'opération avant de fermer. La fermeture libère la connexion Graph et la session en mémoire ; elle ne supprime pas les tâches planifiées."/>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
        </TabControl>

        <Border Grid.Row="2" Background="White" BorderBrush="#D7E0EB" BorderThickness="0,1,0,0" Padding="18,9">
            <DockPanel LastChildFill="False">
                <TextBlock x:Name="StatusTextBlock" Text="Prêt" Foreground="#52677D" VerticalAlignment="Center"/>
                <Button x:Name="CloseButton" Content="Fermer" DockPanel.Dock="Right" Margin="8,0,0,0"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
'@

[xml] $xamlDocument = $xaml
$xmlReader = New-Object System.Xml.XmlNodeReader($xamlDocument)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$driverNameTextBox = $window.FindName('DriverNameTextBox')
$matchModeComboBox = $window.FindName('MatchModeComboBox')
$versionTextBox = $window.FindName('VersionTextBox')
$manufacturerTextBox = $window.FindName('ManufacturerTextBox')
$authenticationModeComboBox = $window.FindName('AuthenticationModeComboBox')
$tenantIdLabel = $window.FindName('TenantIdLabel')
$tenantIdTextBox = $window.FindName('TenantIdTextBox')
$clientIdTextBox = $window.FindName('ClientIdTextBox')
$clientSecretPasswordBox = $window.FindName('ClientSecretPasswordBox')
$certificateComboBox = $window.FindName('CertificateComboBox')
$refreshCertificatesButton = $window.FindName('RefreshCertificatesButton')
$loadProfilesButton = $window.FindName('LoadProfilesButton')
$refreshCatalogButton = $window.FindName('RefreshCatalogButton')
$refreshPausedDriversButton = $window.FindName('RefreshPausedDriversButton')
$refreshDriverProfilesButton = $window.FindName('RefreshDriverProfilesButton')
$driverProfilesComboBox = $window.FindName('DriverProfilesComboBox')
$driverProfilesDataGrid = $window.FindName('DriverProfilesDataGrid')
$driverProfilesStatusTextBlock = $window.FindName('DriverProfilesStatusTextBlock')
$connectionStatusTextBlock = $window.FindName('ConnectionStatusTextBlock')
$profilesDataGrid = $window.FindName('ProfilesDataGrid')
$driversDataGrid = $window.FindName('DriversDataGrid')
$pausedDriversDataGrid = $window.FindName('PausedDriversDataGrid')
$pausedDriversStatusTextBlock = $window.FindName('PausedDriversStatusTextBlock')
$completePauseButton = $window.FindName('CompletePauseButton')
$useSelectedDriverRadioButton = $window.FindName('UseSelectedDriverRadioButton')
$useManualDriverRadioButton = $window.FindName('UseManualDriverRadioButton')
$selectedProfileTextBlock = $window.FindName('SelectedProfileTextBlock')
$selectedDriverTextBox = $window.FindName('SelectedDriverTextBox')
$taskNameTextBox = $window.FindName('TaskNameTextBox')
$elevationStatusTextBlock = $window.FindName('ElevationStatusTextBlock')
$logPathTextBox = $window.FindName('LogPathTextBox')
$simulationButton = $window.FindName('SimulationButton')
$executeButton = $window.FindName('ExecuteButton')
$approveProfileButton = $window.FindName('ApproveProfileButton')
$approveAllButton = $window.FindName('ApproveAllButton')
$installTaskButton = $window.FindName('InstallTaskButton')
$openLogButton = $window.FindName('OpenLogButton')
$activityProgressBar = $window.FindName('ActivityProgressBar')
$outputTextBox = $window.FindName('OutputTextBox')
$statusTextBlock = $window.FindName('StatusTextBlock')
$closeButton = $window.FindName('CloseButton')

$script:ActiveProcess = $null
$script:GraphRunspace = $null
$script:ActivePowerShell = $null
$script:ActiveInvocation = $null
$script:StandardOutputPath = $null
$script:StandardErrorPath = $null
$script:ProcessStatusPath = $null
$script:LastDisplayedOutput = $null
$script:SuccessMessage = $null
$script:CompletionAction = $null
$script:SuppressProcessOutput = $false
$script:SelectedProfile = $null
$script:SelectedDriver = $null
$script:DriverInventories = @{}
$script:Profiles = @()
$script:IsBusy = $false
$script:LastGuiError = $null
$script:SessionAuthentication = $null
$script:PendingAuthenticationSession = $null

function Show-InterfaceBusy {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Busy,

        [string] $Status = 'Prêt'
    )

    $script:IsBusy = $Busy
    $authenticationModeComboBox.IsEnabled = -not $Busy
    $tenantIdTextBox.IsEnabled = -not $Busy
    $clientIdTextBox.IsEnabled = -not $Busy
    $clientSecretPasswordBox.IsEnabled = -not $Busy
    $certificateComboBox.IsEnabled = -not $Busy
    $loadProfilesButton.IsEnabled = -not $Busy
    $refreshCatalogButton.IsEnabled = $false
    $refreshPausedDriversButton.IsEnabled = $false
    $refreshDriverProfilesButton.IsEnabled = $false
    $driverProfilesComboBox.IsEnabled = -not $Busy
    $driverProfilesDataGrid.IsEnabled = -not $Busy
    $profilesDataGrid.IsEnabled = -not $Busy
    $driversDataGrid.IsEnabled = -not $Busy
    $pausedDriversDataGrid.IsEnabled = -not $Busy
    $completePauseButton.IsEnabled = $false
    $approveProfileButton.IsEnabled = $false
    $approveAllButton.IsEnabled = $false
    $refreshCertificatesButton.IsEnabled = $false
    $activityProgressBar.Visibility = if ($Busy) {
        [Windows.Visibility]::Visible
    }
    else {
        [Windows.Visibility]::Collapsed
    }
    $statusTextBlock.Text = $Status
    if (-not $Busy) {
        Show-AuthenticationControl
        Show-TargetControl
        Show-PausedDriverControl
    }
}

function Write-GuiOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [switch] $Replace
    )

    if ($Replace) {
        $outputTextBox.Text = $Message
    }
    else {
        if ($outputTextBox.Text.Length -gt 0) {
            $outputTextBox.AppendText([Environment]::NewLine)
        }
        $outputTextBox.AppendText($Message)
    }
    $outputTextBox.ScrollToEnd()
}

function Show-GuiError {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $script:LastGuiError = $Message
    if ($AutomatedTest) {
        return
    }

    [Windows.MessageBox]::Show(
        $window,
        $Message,
        'Intune Driver Pause',
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Show-GuiWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($AutomatedTest) {
        return
    }
    [Windows.MessageBox]::Show(
        $window,
        $Message,
        'Intune Driver Pause',
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Warning
    ) | Out-Null
}

function Get-SelectedMatchMode {
    $selectedItem = $matchModeComboBox.SelectedItem
    if ($null -eq $selectedItem) {
        return 'Exact'
    }
    return [string] $selectedItem.Content
}

function Get-SelectedAuthenticationMode {
    $selectedItem = $authenticationModeComboBox.SelectedItem
    if ($null -eq $selectedItem) {
        return 'Interactive'
    }
    return [string] $selectedItem.Tag
}

function ConvertTo-SecureMemoryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $secureValue = New-Object Security.SecureString
    foreach ($character in $Value.ToCharArray()) {
        $secureValue.AppendChar($character)
    }
    $secureValue.MakeReadOnly()
    return $secureValue
}

function ConvertFrom-SecureMemoryValue {
    param(
        [Parameter(Mandatory = $true)]
        [securestring] $Value
    )

    $valuePointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($valuePointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($valuePointer)
    }
}

function Get-AuthenticationSessionCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Authentication
    )

    return [pscustomobject] @{
        AuthenticationMode   = $Authentication.AuthenticationMode
        TenantId             = $Authentication.TenantId
        ClientId             = $Authentication.ClientId
        ClientSecret         = if (
            $Authentication.AuthenticationMode -eq 'ClientSecret' -and
            -not [string]::IsNullOrWhiteSpace($Authentication.ClientSecret)
        ) {
            ConvertTo-SecureMemoryValue -Value $Authentication.ClientSecret
        }
        else {
            $null
        }
        CertificateThumbprint = $Authentication.CertificateThumbprint
        CanWrite             = $true
    }
}

function Get-SessionAuthentication {
    if ($null -eq $script:SessionAuthentication) {
        throw 'Connectez-vous et chargez les profils avant de poursuivre.'
    }

    return [pscustomobject] @{
        AuthenticationMode   = $script:SessionAuthentication.AuthenticationMode
        TenantId             = $script:SessionAuthentication.TenantId
        ClientId             = $script:SessionAuthentication.ClientId
        ClientSecret         = if (
            $script:SessionAuthentication.AuthenticationMode -eq 'ClientSecret'
        ) {
            ConvertFrom-SecureMemoryValue -Value $script:SessionAuthentication.ClientSecret
        }
        else {
            ''
        }
        CertificateThumbprint = $script:SessionAuthentication.CertificateThumbprint
        CanWrite             = $script:SessionAuthentication.CanWrite
    }
}

function Clear-AuthenticationSession {
    $script:SessionAuthentication = $null
    $script:PendingAuthenticationSession = $null
    Close-GraphRunspace
}

function Show-AuthenticationControl {
    $authenticationMode = Get-SelectedAuthenticationMode
    $usesApplication = $authenticationMode -in @('ClientSecret', 'Certificate')
    $usesSecret = $authenticationMode -eq 'ClientSecret'
    $usesCertificate = $authenticationMode -eq 'Certificate'

    $clientIdTextBox.IsEnabled = $usesApplication -and -not $script:IsBusy
    $clientSecretPasswordBox.IsEnabled = $usesSecret -and -not $script:IsBusy
    $certificateComboBox.IsEnabled = $usesCertificate -and -not $script:IsBusy
    $refreshCertificatesButton.IsEnabled = $usesCertificate -and -not $script:IsBusy
    $hasReusableSecretSession = $null -ne $script:SessionAuthentication -and
        $script:SessionAuthentication.AuthenticationMode -eq 'ClientSecret' -and
        $script:SessionAuthentication.TenantId -eq $tenantIdTextBox.Text.Trim() -and
        $script:SessionAuthentication.ClientId -eq $clientIdTextBox.Text.Trim()
    $hasRequiredAuthenticationInput = -not $usesSecret -or
        -not [string]::IsNullOrWhiteSpace($clientSecretPasswordBox.Password) -or
        $hasReusableSecretSession
    $loadProfilesButton.IsEnabled = -not $script:IsBusy -and
        $hasRequiredAuthenticationInput
    $refreshCatalogButton.IsEnabled = -not $script:IsBusy -and
        $null -ne $script:SessionAuthentication
    $refreshPausedDriversButton.IsEnabled = -not $script:IsBusy -and
        $null -ne $script:SessionAuthentication
    $refreshDriverProfilesButton.IsEnabled = -not $script:IsBusy -and
        $null -ne $script:SessionAuthentication
    $loadProfilesButton.ToolTip = if ($usesSecret -and -not $hasRequiredAuthenticationInput) {
        'Saisissez la valeur du secret client pour vous connecter.'
    }
    else {
        'Se connecter à Microsoft Graph et charger les profils WUfB Drivers.'
    }
    $tenantIdLabel.Content = if ($usesApplication) {
        'Tenant ID *'
    }
    else {
        'Tenant ID (optionnel)'
    }
    $installTaskButton.ToolTip = if ($usesCertificate) {
        'Créer ou mettre à jour la tâche planifiée horaire pour tous les profils.'
    }
    else {
        'La tâche horaire nécessite une authentification par certificat.'
    }
}

function Show-TargetControl {
    $usesManualTarget = $useManualDriverRadioButton.IsChecked -eq $true
    $driverNameTextBox.IsEnabled = $usesManualTarget -and -not $script:IsBusy
    $matchModeComboBox.IsEnabled = $usesManualTarget -and -not $script:IsBusy
    $manufacturerTextBox.IsEnabled = $usesManualTarget -and -not $script:IsBusy
    $versionTextBox.IsEnabled = $usesManualTarget -and -not $script:IsBusy

    $hasProfile = $null -ne $script:SelectedProfile
    $hasTarget = if ($usesManualTarget) {
        @(ConvertFrom-MultilineText -Value $driverNameTextBox.Text).Count -gt 0
    }
    else {
        $null -ne $script:SelectedDriver
    }
    $canAct = -not $script:IsBusy -and $hasProfile -and $hasTarget

    $canWrite = $null -ne $script:SessionAuthentication -and
        $script:SessionAuthentication.CanWrite
    $simulationButton.IsEnabled = $canAct
    $executeButton.IsEnabled = $canAct -and $canWrite
    $canApprove = $canAct -and $canWrite -and -not $usesManualTarget
    $approveProfileButton.IsEnabled = $canApprove
    $approveAllButton.IsEnabled = $canApprove
    $approvalToolTip = if (-not $canWrite) {
        'Permission requise : DeviceManagementConfiguration.ReadWrite.All.'
    }
    elseif ($usesManualTarget -or $null -eq $script:SelectedDriver) {
        'Sélectionnez un driver dans la liste pour l''approuver par son identifiant.'
    }
    else {
        'Approuver le driver sélectionné pour un déploiement immédiat, après confirmation.'
    }
    $approveProfileButton.ToolTip = $approvalToolTip
    $approveAllButton.ToolTip = $approvalToolTip
    $installTaskButton.IsEnabled = $canAct -and
        $canWrite -and
        (Get-SelectedAuthenticationMode) -eq 'Certificate'
    $executeButton.ToolTip = if ($canWrite) {
        'Suspendre le driver sélectionné dans tous les profils WUfB Drivers.'
    }
    else {
        'Permission requise : DeviceManagementConfiguration.ReadWrite.All.'
    }
}

function Show-PausedDriverControl {
    $selectedDriver = $pausedDriversDataGrid.SelectedItem
    $canWrite = $null -ne $script:SessionAuthentication -and
        $script:SessionAuthentication.CanWrite
    $canComplete = -not $script:IsBusy -and
        $null -ne $selectedDriver -and
        [bool] $selectedDriver.NeedsCompletion

    $completePauseButton.IsEnabled = $canComplete -and $canWrite
    $completePauseButton.ToolTip = if (-not $canWrite) {
        'Permission requise : DeviceManagementConfiguration.ReadWrite.All.'
    }
    elseif ($null -eq $selectedDriver) {
        'Sélectionnez une ligne signalée en jaune.'
    }
    elseif (-not [bool] $selectedDriver.NeedsCompletion) {
        'Ce driver est déjà suspendu dans tous les profils où il est présent.'
    }
    else {
        'Suspendre ce driver uniquement dans les profils encore manquants.'
    }
}

function Get-DriverProfileCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Inventories
    )

    $driversById = @{}
    foreach ($inventory in $Inventories.Values) {
        foreach ($driver in @($inventory)) {
            $driverId = [string] $driver.id
            if ([string]::IsNullOrWhiteSpace($driverId) -or $driversById.ContainsKey($driverId)) {
                continue
            }
            $driversById[$driverId] = [pscustomobject] @{
                DriverId = $driverId
                Label    = '{0} | {1} | {2} | {3}' -f
                    $driver.name, $driver.version, $driver.manufacturer, $driverId
            }
        }
    }
    return @($driversById.Values | Sort-Object Label, DriverId)
}

function Get-DriverProfileRows {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $DriverId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Profiles,

        [Parameter(Mandatory = $true)]
        [hashtable] $Inventories
    )

    $rows = foreach ($driverProfile in $Profiles) {
        $profileId = [string] $driverProfile.id
        if ([string]::IsNullOrWhiteSpace($profileId) -or -not $Inventories.ContainsKey($profileId)) {
            continue
        }
        $driver = $Inventories[$profileId] |
            Where-Object { [string] $_.id -eq $DriverId } |
            Select-Object -First 1
        if ($null -eq $driver) {
            continue
        }
        [pscustomobject] @{
            ProfileId      = $profileId
            ProfileName    = if ([string]::IsNullOrWhiteSpace([string] $driverProfile.displayName)) {
                $profileId
            }
            else {
                [string] $driverProfile.displayName
            }
            ApprovalType   = [string] $driverProfile.approvalType
            ApprovalStatus = [string] $driver.approvalStatus
        }
    }
    return @($rows | Sort-Object ProfileName, ProfileId)
}

function Show-DriverProfiles {
    $driverProfilesDataGrid.ItemsSource = $null
    $selectedDriver = $driverProfilesComboBox.SelectedItem
    $driverId = if ($null -ne $selectedDriver) { [string] $selectedDriver.DriverId } else { '' }
    if ($null -eq $script:SessionAuthentication) {
        $driverProfilesStatusTextBlock.Text = 'Connectez-vous pour charger les profils et drivers.'
    }
    elseif ($driverProfilesComboBox.Items.Count -eq 0) {
        $driverProfilesStatusTextBlock.Text = 'Aucun driver dans le catalogue chargé.'
    }
    elseif ([string]::IsNullOrWhiteSpace($driverId)) {
        $driverProfilesStatusTextBlock.Text = 'Choisissez un driver pour afficher ses profils.'
    }
    else {
        $rows = @(
            Get-DriverProfileRows -DriverId $driverId `
                -Profiles $script:Profiles -Inventories $script:DriverInventories
        )
        $driverProfilesDataGrid.ItemsSource = $rows
        $driverProfilesStatusTextBlock.Text = '{0} profil(s) contenant ce driver dans le catalogue chargé.' -f $rows.Count
    }
}

function Show-DriverProfileCatalog {
    $selectedDriverId = [string] $driverProfilesComboBox.SelectedValue
    $driverProfilesComboBox.ItemsSource = @(
        Get-DriverProfileCatalog -Inventories $script:DriverInventories
    )
    if (-not [string]::IsNullOrWhiteSpace($selectedDriverId)) {
        $driverProfilesComboBox.SelectedValue = $selectedDriverId
    }
    Show-DriverProfiles
}

function Get-PausedDriverSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Profiles,

        [Parameter(Mandatory = $true)]
        [hashtable] $Inventories
    )

    $groups = @{}
    foreach ($driverProfile in $Profiles) {
        $profileId = [string] $driverProfile.id
        if ([string]::IsNullOrWhiteSpace($profileId) -or
            -not $Inventories.ContainsKey($profileId)) {
            continue
        }

        $profileName = if ([string]::IsNullOrWhiteSpace([string] $driverProfile.displayName)) {
            $profileId
        }
        else {
            [string] $driverProfile.displayName
        }

        foreach ($driver in @($Inventories[$profileId])) {
            $driverId = [string] $driver.id
            if ([string]::IsNullOrWhiteSpace($driverId)) {
                continue
            }

            if (-not $groups.ContainsKey($driverId)) {
                $groups[$driverId] = [ordered] @{
                    Driver    = $driver
                    Locations = @{}
                }
            }
            $groups[$driverId].Locations[$profileId] = [pscustomobject] @{
                ProfileId   = $profileId
                ProfileName = $profileName
                IsSuspended = [string]::Equals(
                    [string] $driver.approvalStatus,
                    'suspended',
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
        }
    }

    $rows = @(
        foreach ($driverId in $groups.Keys) {
            $group = $groups[$driverId]
            $locations = @($group.Locations.Values)
            $pausedLocations = @($locations | Where-Object { $_.IsSuspended })
            if ($pausedLocations.Count -eq 0) {
                continue
            }

            $missingLocations = @($locations | Where-Object { -not $_.IsSuspended })
            $allProfileNames = @(
                $locations |
                    Sort-Object ProfileName |
                    ForEach-Object { $_.ProfileName }
            )
            $pausedProfileNames = @(
                $pausedLocations |
                    Sort-Object ProfileName |
                    ForEach-Object { $_.ProfileName }
            )
            $missingProfileNames = @(
                $missingLocations |
                    Sort-Object ProfileName |
                    ForEach-Object { $_.ProfileName }
            )
            $driver = $group.Driver

            [pscustomobject] @{
                DriverId          = [string] $driver.id
                Name              = [string] $driver.name
                Version           = [string] $driver.version
                Manufacturer      = [string] $driver.manufacturer
                AllProfiles       = $allProfileNames -join ', '
                PausedProfiles    = $pausedProfileNames -join ', '
                MissingProfiles   = $missingProfileNames -join ', '
                MissingProfileIds = @($missingLocations | ForEach-Object { $_.ProfileId })
                NeedsCompletion   = $missingLocations.Count -gt 0
                Status            = if ($missingLocations.Count -gt 0) {
                    'À compléter'
                }
                else {
                    'Complet'
                }
            }
        }
    )

    return @(
        $rows |
            Sort-Object `
                @{ Expression = 'NeedsCompletion'; Descending = $true },
                Name,
                Version
    )
}

function Show-PausedDriverSummary {
    $pausedDrivers = @(
        Get-PausedDriverSummary `
            -Profiles $script:Profiles `
            -Inventories $script:DriverInventories
    )
    $pausedDriversDataGrid.ItemsSource = $pausedDrivers
    $incompleteCount = @($pausedDrivers | Where-Object { $_.NeedsCompletion }).Count
    $pausedDriversStatusTextBlock.Text = (
        '{0} driver(s) en pause - {1} suspension(s) à compléter.' -f
        $pausedDrivers.Count,
        $incompleteCount
    )
    Show-PausedDriverControl
}

function Clear-DriverCatalog {
    $script:SelectedProfile = $null
    $script:SelectedDriver = $null
    $script:DriverInventories = @{}
    $script:Profiles = @()
    $profilesDataGrid.ItemsSource = $null
    $driversDataGrid.ItemsSource = $null
    $pausedDriversDataGrid.ItemsSource = $null
    $selectedProfileTextBlock.Text = 'Aucun'
    $selectedDriverTextBox.Text = ''
    $connectionStatusTextBlock.Text = 'Non connecté'
    $pausedDriversStatusTextBlock.Text = 'Connectez-vous pour charger les suspensions.'
    $driverProfilesComboBox.ItemsSource = $null
    $refreshDriverProfilesButton.IsEnabled = -not $script:IsBusy -and
        $null -ne $script:SessionAuthentication
    Show-DriverProfiles
    Show-TargetControl
    Show-PausedDriverControl
}

function Get-AuthenticationConfiguration {
    $authenticationMode = Get-SelectedAuthenticationMode
    $selectedCertificate = $certificateComboBox.SelectedItem
    $clientSecretValue = $clientSecretPasswordBox.Password

    if ($authenticationMode -in @('ClientSecret', 'Certificate') -and
        [string]::IsNullOrWhiteSpace($tenantIdTextBox.Text)) {
        throw 'Saisissez le Tenant ID.'
    }
    if ($authenticationMode -in @('ClientSecret', 'Certificate') -and
        [string]::IsNullOrWhiteSpace($clientIdTextBox.Text)) {
        throw "Saisissez l'Application ID."
    }
    if ($authenticationMode -eq 'ClientSecret' -and
        [string]::IsNullOrWhiteSpace($clientSecretValue)) {
        $canReuseSession = $null -ne $script:SessionAuthentication -and
            $script:SessionAuthentication.AuthenticationMode -eq 'ClientSecret' -and
            $script:SessionAuthentication.TenantId -eq $tenantIdTextBox.Text.Trim() -and
            $script:SessionAuthentication.ClientId -eq $clientIdTextBox.Text.Trim()
        if ($canReuseSession) {
            $clientSecretValue = ConvertFrom-SecureMemoryValue `
                -Value $script:SessionAuthentication.ClientSecret
        }
        else {
            throw 'Saisissez le secret client.'
        }
    }
    if ($authenticationMode -eq 'Certificate' -and $null -eq $selectedCertificate) {
        throw 'Sélectionnez un certificat machine contenant une clé privée.'
    }

    return [pscustomobject] @{
        AuthenticationMode   = $authenticationMode
        TenantId             = $tenantIdTextBox.Text.Trim()
        ClientId             = $clientIdTextBox.Text.Trim()
        ClientSecret         = if ($authenticationMode -eq 'ClientSecret') {
            $clientSecretValue
        }
        else {
            ''
        }
        CertificateThumbprint = if ($null -ne $selectedCertificate) {
            [string] $selectedCertificate.Thumbprint
        }
        else {
            ''
        }
    }
}

function Get-GuiConfiguration {
    param(
        [switch] $Approval
    )

    $authentication = Get-SessionAuthentication
    if ($null -eq $script:SelectedProfile) {
        throw 'Sélectionnez un profil WUfB Drivers.'
    }
    if ([string]::IsNullOrWhiteSpace($logPathTextBox.Text)) {
        throw 'Saisissez le chemin du journal.'
    }
    if (-not $Approval -and [string]::IsNullOrWhiteSpace($taskNameTextBox.Text)) {
        throw 'Saisissez le nom de la tâche planifiée.'
    }

    $usesSelectedDriver = $useSelectedDriverRadioButton.IsChecked -eq $true
    if ($Approval -and (-not $usesSelectedDriver -or -not $authentication.CanWrite)) {
        throw 'L''approbation exige un driver sélectionné et la permission DeviceManagementConfiguration.ReadWrite.All.'
    }
    if ($usesSelectedDriver) {
        if ($null -eq $script:SelectedDriver) {
            throw 'Sélectionnez un driver dans la liste.'
        }
        $driverNames = @([string] $script:SelectedDriver.name)
        $driverIds = @([string] $script:SelectedDriver.id)
        $manufacturer = [string] $script:SelectedDriver.manufacturer
        $driverVersion = [string] $script:SelectedDriver.version
        $targetMode = 'Selected'
    }
    else {
        $driverNames = @(ConvertFrom-MultilineText -Value $driverNameTextBox.Text)
        if ($driverNames.Count -eq 0) {
            throw 'Saisissez au moins un nom de pilote.'
        }
        $driverIds = @()
        $manufacturer = $manufacturerTextBox.Text.Trim()
        $driverVersion = $versionTextBox.Text.Trim()
        $targetMode = 'Manual'
    }

    return [pscustomobject] @{
        DriverNames          = $driverNames
        DriverIds            = $driverIds
        TargetMode           = $targetMode
        NameMatchMode        = Get-SelectedMatchMode
        Manufacturer         = $manufacturer
        DriverVersion        = $driverVersion
        ProfileIds           = @()
        ProfileNames         = @()
        AuthenticationMode   = $authentication.AuthenticationMode
        TenantId             = $authentication.TenantId
        ClientId             = $authentication.ClientId
        ClientSecret         = $authentication.ClientSecret
        CertificateThumbprint = $authentication.CertificateThumbprint
        TaskName             = $taskNameTextBox.Text.Trim()
        LogPath              = [IO.Path]::GetFullPath($logPathTextBox.Text.Trim())
    }
}

function Get-DriverApprovalConfiguration {
    param(
        [switch] $AllProfiles
    )

    $configuration = Get-GuiConfiguration -Approval
    if (-not $AllProfiles) {
        $profileId = [string] $script:SelectedProfile.id
        if ([string]::IsNullOrWhiteSpace($profileId)) {
            throw 'Le profil sélectionné ne contient pas d''identifiant.'
        }
        $configuration.ProfileIds = @($profileId)
    }
    if ([string]::IsNullOrWhiteSpace([string] $configuration.DriverIds[0])) {
        throw 'Le driver sélectionné ne contient pas d''identifiant.'
    }
    return $configuration
}

function Show-DriverActionResult {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Configuration,

        [Parameter(Mandatory = $true)]
        [ValidateSet('approved', 'suspended')]
        [string] $ApprovalStatus
    )

    $profileIds = if ($Configuration.ProfileIds.Count -gt 0) {
        @($Configuration.ProfileIds)
    }
    else {
        @($script:DriverInventories.Keys)
    }
    foreach ($profileId in $profileIds) {
        if ($script:DriverInventories.ContainsKey($profileId)) {
            foreach ($driver in @($script:DriverInventories[$profileId])) {
                if ([string] $driver.id -in $Configuration.DriverIds) {
                    $driver.approvalStatus = $ApprovalStatus
                }
            }
        }
    }
    $driversDataGrid.Items.Refresh()
    if ($null -ne $script:SelectedDriver) {
        $selectedDriverTextBox.Text = '{0} | {1} | {2} | état: {3}' -f
            $script:SelectedDriver.name,
            $script:SelectedDriver.version,
            $script:SelectedDriver.manufacturer,
            $script:SelectedDriver.approvalStatus
    }
    Show-PausedDriverSummary
    Show-DriverProfiles
}

function Get-DriverActionCompletion {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Configuration,

        [Parameter(Mandatory = $true)]
        [ValidateSet('approved', 'suspended')]
        [string] $ApprovalStatus
    )

    $target = [pscustomobject] @{
        DriverIds  = @($Configuration.DriverIds)
        ProfileIds = @($Configuration.ProfileIds)
    }
    $showResult = Get-Command Show-DriverActionResult -CommandType Function
    return {
        & $showResult -Configuration $target -ApprovalStatus $ApprovalStatus
    }.GetNewClosure()
}

function Invoke-GuiDriverApproval {
    param(
        [switch] $AllProfiles
    )

    $configuration = $null
    try {
        $configuration = Get-DriverApprovalConfiguration -AllProfiles:$AllProfiles
        $scopeDescription = if ($AllProfiles) {
            'tous les profils WUfB Drivers où il est présent'
        }
        else {
            "le profil '$($script:SelectedProfile.displayName)' ($($script:SelectedProfile.id))"
        }
        $confirmation = [Windows.MessageBox]::Show(
            $window,
            ("Approuver maintenant '$($configuration.DriverNames[0])' " +
                "($($configuration.DriverIds[0])) dans $scopeDescription ?`r`n`r`n" +
                "Le déploiement sera autorisé immédiatement.`r`n" +
                "Attention : une tâche horaire ciblant ce driver pourra le suspendre à nouveau. " +
                "Désactivez-la si vous souhaitez conserver l'approbation."),
            'Confirmer l''approbation',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($confirmation -ne [Windows.MessageBoxResult]::Yes) {
            return
        }

        Save-GuiSetting
        $onSuccess = Get-DriverActionCompletion -Configuration $configuration -ApprovalStatus approved
        $command = Get-WatchCommand -Configuration $configuration -Action Approve
        Invoke-TrackedPowerShell `
            -Command $command `
            -Activity 'Approbation et vérification en cours' `
            -SuccessMessage 'Approbation vérifiée avec succès' `
            -ClientSecret $configuration.ClientSecret `
            -OnSuccess $onSuccess
    }
    catch {
        Show-GuiError -Message (
            "$($_.Exception.Message)`r`nActualisez le catalogue avant de réessayer si une opération a commencé."
        )
    }
    finally {
        if ($null -ne $configuration) {
            $configuration.ClientSecret = ''
        }
        $clientSecretPasswordBox.Password = ''
    }
}

function Get-PausedDriverCompletionConfiguration {
    $authentication = Get-SessionAuthentication
    $pausedDriver = $pausedDriversDataGrid.SelectedItem
    if ($null -eq $pausedDriver) {
        throw 'Sélectionnez un driver dont la suspension est à compléter.'
    }
    if (-not [bool] $pausedDriver.NeedsCompletion) {
        throw 'Le driver sélectionné est déjà suspendu dans tous ses profils.'
    }

    $missingProfileIds = @($pausedDriver.MissingProfileIds)
    if ($missingProfileIds.Count -eq 0) {
        throw 'Aucun profil à compléter pour le driver sélectionné.'
    }
    if ([string]::IsNullOrWhiteSpace($logPathTextBox.Text)) {
        throw "Saisissez le chemin du journal dans l'onglet de suspension."
    }

    return [pscustomobject] @{
        DriverNames          = @([string] $pausedDriver.Name)
        DriverIds            = @([string] $pausedDriver.DriverId)
        TargetMode           = 'Selected'
        NameMatchMode        = 'Exact'
        Manufacturer         = [string] $pausedDriver.Manufacturer
        DriverVersion        = [string] $pausedDriver.Version
        ProfileIds           = $missingProfileIds
        ProfileNames         = @()
        AuthenticationMode   = $authentication.AuthenticationMode
        TenantId             = $authentication.TenantId
        ClientId             = $authentication.ClientId
        ClientSecret         = $authentication.ClientSecret
        CertificateThumbprint = $authentication.CertificateThumbprint
        TaskName             = $taskNameTextBox.Text.Trim()
        LogPath              = [IO.Path]::GetFullPath($logPathTextBox.Text.Trim())
    }
}

function Save-GuiSetting {
    $settingsDirectory = Split-Path -Path $settingsPath -Parent
    if (-not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) {
        New-Item -Path $settingsDirectory -ItemType Directory -Force | Out-Null
    }

    $selectedCertificate = $certificateComboBox.SelectedItem
    [pscustomobject] @{
        DriverNames          = @(ConvertFrom-MultilineText -Value $driverNameTextBox.Text)
        TargetMode           = if ($useManualDriverRadioButton.IsChecked -eq $true) {
            'Manual'
        }
        else {
            'Selected'
        }
        NameMatchMode        = Get-SelectedMatchMode
        Manufacturer         = $manufacturerTextBox.Text.Trim()
        DriverVersion        = $versionTextBox.Text.Trim()
        AuthenticationMode   = Get-SelectedAuthenticationMode
        TenantId             = $tenantIdTextBox.Text.Trim()
        ClientId             = $clientIdTextBox.Text.Trim()
        CertificateThumbprint = if ($null -ne $selectedCertificate) {
            [string] $selectedCertificate.Thumbprint
        }
        else {
            ''
        }
        TaskName             = $taskNameTextBox.Text.Trim()
        LogPath              = $logPathTextBox.Text.Trim()
    } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Read-CertificateList {
    param(
        [string] $PreferredThumbprint
    )

    try {
        $certificates = @(
            Get-ChildItem -Path 'Cert:\LocalMachine\My' |
                Where-Object { $_.HasPrivateKey } |
                Sort-Object NotAfter -Descending |
                ForEach-Object {
                    [pscustomobject] @{
                        Thumbprint = $_.Thumbprint
                        Label      = '{0} | expire le {1:yyyy-MM-dd} | {2}' -f
                            $_.Subject, $_.NotAfter, $_.Thumbprint
                    }
                }
        )

        $certificateComboBox.ItemsSource = $certificates
        if (-not [string]::IsNullOrWhiteSpace($PreferredThumbprint)) {
            $certificateComboBox.SelectedValue = $PreferredThumbprint
        }
        if ($certificateComboBox.SelectedIndex -lt 0 -and $certificates.Count -gt 0) {
            $certificateComboBox.SelectedIndex = 0
        }

        if ($certificates.Count -eq 0) {
            $statusTextBlock.Text = 'Aucun certificat avec clé privée dans LocalMachine\My.'
        }
    }
    catch {
        Show-GuiError -Message "Lecture des certificats impossible : $($_.Exception.Message)"
    }
}

function Import-GuiSetting {
    $logPathTextBox.Text = $defaultLogPath
    $elevationStatusTextBlock.Text = if (Get-IsAdministrator) {
        'Administrateur'
    }
    else {
        'Standard - une demande UAC sera affichée'
    }

    $preferredThumbprint = $null
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $driverNameTextBox.Text = @($settings.DriverNames) -join [Environment]::NewLine
            $manufacturerTextBox.Text = [string] $settings.Manufacturer
            $versionTextBox.Text = [string] $settings.DriverVersion
            $tenantIdTextBox.Text = [string] $settings.TenantId
            $clientIdTextBox.Text = [string] $settings.ClientId
            $taskNameTextBox.Text = [string] $settings.TaskName
            $logPathTextBox.Text = [string] $settings.LogPath
            $preferredThumbprint = [string] $settings.CertificateThumbprint
            $savedAuthenticationMode = if (
                $null -ne $settings.PSObject.Properties['AuthenticationMode']
            ) {
                [string] $settings.AuthenticationMode
            }
            else {
                'Certificate'
            }
            $savedTargetMode = if ($null -ne $settings.PSObject.Properties['TargetMode']) {
                [string] $settings.TargetMode
            }
            elseif (@($settings.DriverNames).Count -gt 0) {
                'Manual'
            }
            else {
                'Selected'
            }
            if ($savedTargetMode -eq 'Manual') {
                $useManualDriverRadioButton.IsChecked = $true
            }
            else {
                $useSelectedDriverRadioButton.IsChecked = $true
            }

            for ($index = 0; $index -lt $matchModeComboBox.Items.Count; $index++) {
                if ([string] $matchModeComboBox.Items[$index].Content -eq [string] $settings.NameMatchMode) {
                    $matchModeComboBox.SelectedIndex = $index
                    break
                }
            }
            for ($index = 0; $index -lt $authenticationModeComboBox.Items.Count; $index++) {
                if ([string] $authenticationModeComboBox.Items[$index].Tag -eq $savedAuthenticationMode) {
                    $authenticationModeComboBox.SelectedIndex = $index
                    break
                }
            }
        }
        catch {
            $statusTextBlock.Text = "Paramètres précédents ignorés : $($_.Exception.Message)"
        }
    }

    Read-CertificateList -PreferredThumbprint $preferredThumbprint
    Show-AuthenticationControl
    Show-TargetControl
}

function Get-CatalogCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Profiles', 'Drivers', 'Snapshot')]
        [string] $Resource,

        [Parameter(Mandatory = $true)]
        [object] $Authentication,

        [string] $ProfileId,

        [switch] $UseCurrentContext
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add('& {0}' -f (ConvertTo-PowerShellStringLiteral -Value $catalogScriptPath))
    $parts.Add('-Resource {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Resource))
    $parts.Add('-KeepGraphConnection')
    if ($Authentication.AuthenticationMode -eq 'ClientSecret') {
        $parts.Add('-ClientSecret $GuiClientSecret')
    }
    if ($Resource -eq 'Drivers') {
        if ([string]::IsNullOrWhiteSpace($ProfileId)) {
            throw 'Un profil est requis pour lister les drivers.'
        }
        $parts.Add('-ProfileId {0}' -f (ConvertTo-PowerShellStringLiteral -Value $ProfileId))
    }

    $authenticationMode = if ($UseCurrentContext -and $Authentication.AuthenticationMode -ne 'ClientSecret') {
        'CurrentContext'
    }
    else {
        $Authentication.AuthenticationMode
    }
    $parts.Add('-AuthenticationMode {0}' -f (
            ConvertTo-PowerShellStringLiteral -Value $authenticationMode
        ))
    if (-not [string]::IsNullOrWhiteSpace($Authentication.TenantId)) {
        $parts.Add('-TenantId {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Authentication.TenantId
            ))
    }
    if ($Authentication.AuthenticationMode -ne 'Interactive' -and
        -not [string]::IsNullOrWhiteSpace($Authentication.ClientId)) {
        $parts.Add('-ClientId {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Authentication.ClientId
            ))
    }
    if ($Authentication.AuthenticationMode -eq 'Certificate') {
        $parts.Add('-CertificateThumbprint {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Authentication.CertificateThumbprint
            ))
        $parts.Add('-CertificateStoreLocation ''LocalMachine''')
    }

    return $parts -join ' '
}

function Get-WatchCommand {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Configuration,

        [switch] $Simulation,

        [ValidateSet('Suspend', 'Approve')]
        [string] $Action = 'Suspend'
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add('& {0}' -f (ConvertTo-PowerShellStringLiteral -Value $watchScriptPath))
    $parts.Add('-Action {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Action))
    $parts.Add('-KeepGraphConnection')
    if ($Configuration.AuthenticationMode -eq 'ClientSecret') {
        $parts.Add('-ClientSecret $GuiClientSecret')
    }
    if ($Configuration.TargetMode -eq 'Selected') {
        $parts.Add('-DriverId {0}' -f (
                ConvertTo-PowerShellArrayLiteral -Value $Configuration.DriverIds
            ))
    }
    else {
        $parts.Add('-DriverName {0}' -f (
                ConvertTo-PowerShellArrayLiteral -Value $Configuration.DriverNames
            ))
        $parts.Add('-NameMatchMode {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Configuration.NameMatchMode
            ))
        if (-not [string]::IsNullOrWhiteSpace($Configuration.Manufacturer)) {
            $parts.Add('-Manufacturer {0}' -f (
                    ConvertTo-PowerShellStringLiteral -Value $Configuration.Manufacturer
                ))
        }
        if (-not [string]::IsNullOrWhiteSpace($Configuration.DriverVersion)) {
            $parts.Add('-DriverVersion {0}' -f (
                    ConvertTo-PowerShellStringLiteral -Value $Configuration.DriverVersion
                ))
        }
    }
    if ($Configuration.ProfileIds.Count -gt 0) {
        $parts.Add('-ProfileId {0}' -f (
                ConvertTo-PowerShellArrayLiteral -Value $Configuration.ProfileIds
            ))
    }

    $authenticationMode = if ($Configuration.AuthenticationMode -eq 'ClientSecret') {
        'ClientSecret'
    }
    else {
        'CurrentContext'
    }
    $parts.Add('-AuthenticationMode {0}' -f (
            ConvertTo-PowerShellStringLiteral -Value $authenticationMode
        ))
    if (-not [string]::IsNullOrWhiteSpace($Configuration.TenantId)) {
        $parts.Add('-TenantId {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Configuration.TenantId
            ))
    }
    if ($Configuration.AuthenticationMode -ne 'Interactive' -and
        -not [string]::IsNullOrWhiteSpace($Configuration.ClientId)) {
        $parts.Add('-ClientId {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Configuration.ClientId
            ))
    }
    if ($Configuration.AuthenticationMode -eq 'Certificate') {
        $parts.Add('-CertificateThumbprint {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Configuration.CertificateThumbprint
            ))
        $parts.Add('-CertificateStoreLocation ''LocalMachine''')
    }
    $parts.Add('-LogPath {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Configuration.LogPath))

    if ($Simulation) {
        $parts.Add('-WhatIf')
    }

    return $parts -join ' '
}

function Get-RegisterTaskCommand {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Configuration
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add('& {0}' -f (ConvertTo-PowerShellStringLiteral -Value $registerScriptPath))
    if ($Configuration.TargetMode -eq 'Selected') {
        $parts.Add('-DriverId {0}' -f (
                ConvertTo-PowerShellArrayLiteral -Value $Configuration.DriverIds
            ))
    }
    else {
        $parts.Add('-DriverName {0}' -f (
                ConvertTo-PowerShellArrayLiteral -Value $Configuration.DriverNames
            ))
        $parts.Add('-NameMatchMode {0}' -f (
                ConvertTo-PowerShellStringLiteral -Value $Configuration.NameMatchMode
            ))
        if (-not [string]::IsNullOrWhiteSpace($Configuration.Manufacturer)) {
            $parts.Add('-Manufacturer {0}' -f (
                    ConvertTo-PowerShellStringLiteral -Value $Configuration.Manufacturer
                ))
        }
        if (-not [string]::IsNullOrWhiteSpace($Configuration.DriverVersion)) {
            $parts.Add('-DriverVersion {0}' -f (
                    ConvertTo-PowerShellStringLiteral -Value $Configuration.DriverVersion
                ))
        }
    }
    if ($Configuration.ProfileIds.Count -gt 0) {
        $parts.Add('-ProfileId {0}' -f (
                ConvertTo-PowerShellArrayLiteral -Value $Configuration.ProfileIds
            ))
    }

    $parts.Add('-TenantId {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Configuration.TenantId))
    $parts.Add('-ClientId {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Configuration.ClientId))
    $parts.Add('-CertificateThumbprint {0}' -f (
            ConvertTo-PowerShellStringLiteral -Value $Configuration.CertificateThumbprint
        ))
    $parts.Add('-TaskName {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Configuration.TaskName))
    $parts.Add('-LogPath {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Configuration.LogPath))
    return $parts -join ' '
}

function Get-GraphRunspace {
    if ($null -eq $script:GraphRunspace) {
        $runspace = [RunspaceFactory]::CreateRunspace()
        try {
            $runspace.ApartmentState = [Threading.ApartmentState]::STA
            $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $runspace.Open()
            $script:GraphRunspace = $runspace
        }
        catch {
            $runspace.Dispose()
            throw
        }
    }
    return $script:GraphRunspace
}

function Close-GraphRunspace {
    if ($null -ne $script:ActivePowerShell) {
        throw 'Attendez la fin de l''opération avant de modifier la connexion Graph.'
    }
    if ($null -eq $script:GraphRunspace) {
        return
    }

    $cleanup = [PowerShell]::Create()
    try {
        $cleanup.Runspace = $script:GraphRunspace
        $null = $cleanup.AddScript({
            $ErrorActionPreference = 'Stop'
            if ($null -ne (Get-Command Get-MgContext -ErrorAction SilentlyContinue) -and
                $null -ne (Get-MgContext)) {
                Disconnect-MgGraph -ErrorAction Stop | Out-Null
            }
        })
        $null = $cleanup.Invoke()
        if ($cleanup.HadErrors) {
            throw $cleanup.Streams.Error[0]
        }
    }
    finally {
        $cleanup.Dispose()
        $script:GraphRunspace.Dispose()
        $script:GraphRunspace = $null
    }
}

function Invoke-TrackedPowerShell {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [Parameter(Mandatory = $true)]
        [string] $Activity,

        [Parameter(Mandatory = $true)]
        [string] $SuccessMessage,

        [string] $ClientSecret,

        [scriptblock] $OnSuccess,

        [switch] $SuppressOutput,

        [switch] $Elevated
    )

    if ($null -ne $script:ActivePowerShell -or
        ($null -ne $script:ActiveProcess -and -not $script:ActiveProcess.HasExited)) {
        throw 'Une opération est déjà en cours.'
    }

    $operationId = [guid]::NewGuid().ToString('N')
    $script:StandardOutputPath = Join-Path $env:TEMP "IntuneDriverPause.Gui.$operationId.out.log"
    $script:StandardErrorPath = Join-Path $env:TEMP "IntuneDriverPause.Gui.$operationId.err.log"
    $script:ProcessStatusPath = Join-Path $env:TEMP "IntuneDriverPause.Gui.$operationId.status"
    $script:LastDisplayedOutput = $null
    $script:SuccessMessage = $SuccessMessage
    $script:CompletionAction = $OnSuccess
    $script:SuppressProcessOutput = $SuppressOutput

    Write-GuiOutput -Message "=== $Activity ===`r`n" -Replace
    Show-InterfaceBusy -Busy $true -Status $Activity

    if (-not $Elevated) {
        try {
            $script:ActivePowerShell = [PowerShell]::Create()
            $script:ActivePowerShell.Runspace = Get-GraphRunspace
            $secureClientSecret = if (-not [string]::IsNullOrWhiteSpace($ClientSecret)) {
                ConvertTo-SecureMemoryValue -Value $ClientSecret
            }
            else {
                $null
            }
            $null = $script:ActivePowerShell.AddScript({
                param(
                    [string] $OperationCommand,
                    [securestring] $GuiClientSecret,
                    [string] $OutputPath,
                    [string] $ErrorPath,
                    [string] $StatusPath
                )

                $ErrorActionPreference = 'Stop'
                try {
                    & ([scriptblock]::Create($OperationCommand)) |
                        Out-File -LiteralPath $OutputPath -Encoding utf8
                    '0' | Set-Content -LiteralPath $StatusPath -Encoding ascii
                }
                catch {
                    $errorException = $_.Exception
                    while ($null -ne $errorException.InnerException) {
                        $errorException = $errorException.InnerException
                    }
                    $errorException.Message | Out-File -LiteralPath $ErrorPath -Encoding utf8
                    '1' | Set-Content -LiteralPath $StatusPath -Encoding ascii
                }
                finally {
                    $GuiClientSecret = $null
                }
            }).AddArgument($Command).AddArgument($secureClientSecret).AddArgument($script:StandardOutputPath).
                AddArgument($script:StandardErrorPath).AddArgument($script:ProcessStatusPath)
            $script:ActiveInvocation = $script:ActivePowerShell.BeginInvoke()
        }
        catch {
            if ($null -ne $script:ActivePowerShell) {
                $script:ActivePowerShell.Dispose()
                $script:ActivePowerShell = $null
            }
            Show-InterfaceBusy -Busy $false
            throw
        }
        return
    }

    $wrappedCommand = 'try {{ {0} *>&1 | Out-File -LiteralPath {1} -Encoding utf8; ''0'' | Set-Content -LiteralPath {3} -Encoding ascii; exit 0 }} catch {{ $errorException = $_.Exception; while ($null -ne $errorException.InnerException) {{ $errorException = $errorException.InnerException }}; $errorException.Message | Out-File -LiteralPath {2} -Encoding utf8; ''1'' | Set-Content -LiteralPath {3} -Encoding ascii; exit 1 }}' -f
        $Command,
        (ConvertTo-PowerShellStringLiteral -Value $script:StandardOutputPath),
        (ConvertTo-PowerShellStringLiteral -Value $script:StandardErrorPath),
        (ConvertTo-PowerShellStringLiteral -Value $script:ProcessStatusPath)

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrappedCommand))
    $argumentParts = @('-NoLogo', '-NoProfile')
    $argumentParts += '-NonInteractive'
    $argumentParts += @('-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
    $arguments = $argumentParts -join ' '

    try {
        $script:ActiveProcess = Start-Process `
            -FilePath $powerShellExecutable `
            -ArgumentList $arguments `
            -Verb RunAs `
            -PassThru
    }
    catch {
        Show-InterfaceBusy -Busy $false
        throw
    }
}

function Get-CleanProcessFileContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) {
        return ''
    }
    return [regex]::Replace($content, '(?s)#< CLIXML.*$', '').Trim()
}

function Show-CatalogResult {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json,

        [switch] $NotifyReadOnly
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw 'Microsoft Graph a retourné un catalogue vide.'
    }
    $catalog = $Json | ConvertFrom-Json
    $profiles = @($catalog.profiles)
    $script:Profiles = $profiles
    $script:DriverInventories = @{}
    foreach ($inventory in @($catalog.inventories)) {
        $script:DriverInventories[[string] $inventory.profileId] = @($inventory.value)
    }

    if ($null -ne $script:PendingAuthenticationSession) {
        $script:SessionAuthentication = $script:PendingAuthenticationSession
        $script:PendingAuthenticationSession = $null
    }
    if ($null -eq $script:SessionAuthentication) {
        throw 'La session Graph est absente après le chargement du catalogue.'
    }

    $canWrite = if ($null -ne $catalog.PSObject.Properties['capabilities']) {
        [bool] $catalog.capabilities.canWrite
    }
    else {
        $true
    }
    $script:SessionAuthentication.CanWrite = $canWrite
    if ($script:SessionAuthentication.AuthenticationMode -eq 'ClientSecret') {
        $clientSecretPasswordBox.Password = ''
    }

    $profilesDataGrid.ItemsSource = $profiles
    Show-DriverProfileCatalog
    Show-PausedDriverSummary
    $connectionStatusTextBlock.Text = if ($canWrite) {
        'Session {0} active - {1} profil(s)' -f
            $script:SessionAuthentication.AuthenticationMode,
            $profiles.Count
    }
    else {
        'Session lecture seule - {0} profil(s)' -f $profiles.Count
    }
    Write-GuiOutput -Message (
        'Catalogue actualisé. {0} profil(s) WUfB Drivers chargé(s).' -f $profiles.Count
    ) -Replace

    if ($NotifyReadOnly -and -not $canWrite) {
        Show-GuiWarning -Message (
            'La connexion est en lecture seule. Pour suspendre ou approuver un driver, ajoutez ' +
            'la permission applicative Microsoft Graph ' +
            'DeviceManagementConfiguration.ReadWrite.All puis accordez le ' +
            'consentement administrateur.'
        )
    }
}

function Invoke-CatalogRefresh {
    $authentication = Get-SessionAuthentication
    $script:PendingAuthenticationSession = $script:SessionAuthentication
    Clear-DriverCatalog
    $connectionStatusTextBlock.Text = 'Actualisation en cours...'
    $pausedDriversStatusTextBlock.Text = 'Actualisation des suspensions en cours...'
    $command = Get-CatalogCommand -Resource Snapshot -Authentication $authentication -UseCurrentContext
    $onSuccess = {
        param($json)
        Show-CatalogResult -Json $json
    }
    try {
        Invoke-TrackedPowerShell `
            -Command $command `
            -Activity 'Actualisation des profils, drivers et suspensions' `
            -SuccessMessage 'Catalogue WUfB Drivers actualisé' `
            -ClientSecret $authentication.ClientSecret `
            -OnSuccess $onSuccess `
            -SuppressOutput
    }
    finally {
        $authentication.ClientSecret = ''
    }
}

function Get-TrackedPowerShellDiagnostics {
    if ($null -eq $script:ActivePowerShell) {
        return ''
    }

    $streams = $script:ActivePowerShell.Streams
    $messages = @(
        $streams.Information | ForEach-Object { [string] $_.MessageData }
        $streams.Warning | ForEach-Object { '[WARN] {0}' -f $_.Message }
        $streams.Verbose | ForEach-Object { '[VERBOSE] {0}' -f $_.Message }
        $streams.Debug | ForEach-Object { '[DEBUG] {0}' -f $_.Message }
    )
    return $messages -join [Environment]::NewLine
}

function Update-TrackedPowerShell {
    if ($null -eq $script:ActiveProcess -and $null -eq $script:ActivePowerShell) {
        return
    }

    $standardOutput = Get-CleanProcessFileContent -Path $script:StandardOutputPath
    $standardError = Get-CleanProcessFileContent -Path $script:StandardErrorPath
    $diagnostics = Get-TrackedPowerShellDiagnostics
    $combinedOutput = @($standardOutput, $diagnostics, $standardError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $combinedOutput = $combinedOutput -join [Environment]::NewLine

    if (-not $script:SuppressProcessOutput -and
        -not [string]::IsNullOrWhiteSpace($combinedOutput) -and
        $combinedOutput -ne $script:LastDisplayedOutput) {
        $script:LastDisplayedOutput = $combinedOutput
        Write-GuiOutput -Message $combinedOutput -Replace
    }

    $invocationError = ''
    if ($null -ne $script:ActivePowerShell) {
        if (-not $script:ActiveInvocation.IsCompleted) {
            return
        }
        try {
            $null = $script:ActivePowerShell.EndInvoke($script:ActiveInvocation)
            if ($script:ActivePowerShell.HadErrors -and
                -not (Test-Path -LiteralPath $script:ProcessStatusPath -PathType Leaf)) {
                $invocationError = ($script:ActivePowerShell.Streams.Error |
                    ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            }
        }
        catch {
            $invocationError = $_.Exception.Message
        }
        finally {
            $diagnostics = Get-TrackedPowerShellDiagnostics
            $script:ActivePowerShell.Dispose()
            $script:ActivePowerShell = $null
            $script:ActiveInvocation = $null
        }
    }
    else {
        if (-not $script:ActiveProcess.HasExited) {
            return
        }
        $script:ActiveProcess.WaitForExit()
        $script:ActiveProcess.Dispose()
        $script:ActiveProcess = $null
    }

    $standardOutput = Get-CleanProcessFileContent -Path $script:StandardOutputPath
    $standardError = Get-CleanProcessFileContent -Path $script:StandardErrorPath
    if (-not [string]::IsNullOrWhiteSpace($invocationError)) {
        $standardError = @($standardError, $invocationError) -join [Environment]::NewLine
    }
    $combinedOutput = @($standardOutput, $diagnostics, $standardError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $combinedOutput = $combinedOutput -join [Environment]::NewLine
    if (-not $script:SuppressProcessOutput -and
        -not [string]::IsNullOrWhiteSpace($combinedOutput) -and
        $combinedOutput -ne $script:LastDisplayedOutput) {
        $script:LastDisplayedOutput = $combinedOutput
        Write-GuiOutput -Message $combinedOutput -Replace
    }
    $exitCode = if ([string]::IsNullOrWhiteSpace($invocationError) -and
        (Test-Path -LiteralPath $script:ProcessStatusPath -PathType Leaf)) {
        [int] (Get-Content -LiteralPath $script:ProcessStatusPath -Raw).Trim()
    }
    else {
        1
    }
    foreach ($temporaryPath in @(
            $script:StandardOutputPath,
            $script:StandardErrorPath,
            $script:ProcessStatusPath
        )) {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($exitCode -eq 0) {
        try {
            if ($null -ne $script:CompletionAction) {
                & $script:CompletionAction $standardOutput
            }
            Show-InterfaceBusy -Busy $false -Status $script:SuccessMessage
            if ($script:SuppressProcessOutput -and -not [string]::IsNullOrWhiteSpace($diagnostics)) {
                Write-GuiOutput -Message $diagnostics
            }
            elseif (-not $script:SuppressProcessOutput -and
                [string]::IsNullOrWhiteSpace($combinedOutput)) {
                Write-GuiOutput -Message $script:SuccessMessage
            }
        }
        catch {
            $script:PendingAuthenticationSession = $null
            if ($script:SuppressProcessOutput) {
                $connectionStatusTextBlock.Text = 'Échec du chargement du catalogue'
                if (-not [string]::IsNullOrWhiteSpace($diagnostics)) {
                    Write-GuiOutput -Message $diagnostics
                }
            }
            Show-InterfaceBusy -Busy $false -Status "Échec du traitement du résultat"
            Show-GuiError -Message $_.Exception.Message
        }
    }
    else {
        $script:PendingAuthenticationSession = $null
        Show-InterfaceBusy -Busy $false -Status "Échec de l'opération"
        if ($script:SuppressProcessOutput) {
            $connectionStatusTextBlock.Text = 'Échec du chargement du catalogue'
            if (-not [string]::IsNullOrWhiteSpace($combinedOutput)) {
                Write-GuiOutput -Message $combinedOutput -Replace
            }
        }
        if ([string]::IsNullOrWhiteSpace($combinedOutput)) {
            Write-GuiOutput -Message "Le processus s'est terminé avec le code $exitCode."
        }
        $errorDetail = if (-not [string]::IsNullOrWhiteSpace($standardError)) {
            $standardError.Trim()
        }
        elseif (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
            $standardOutput.Trim()
        }
        else {
            "Le processus s'est terminé avec le code $exitCode."
        }
        if ($errorDetail.Length -gt 1600) {
            $errorDetail = $errorDetail.Substring(0, 1600) + '...'
        }
        Show-GuiError -Message "L'opération a échoué :`r`n`r`n$errorDetail"
    }
    $script:CompletionAction = $null
    $script:SuppressProcessOutput = $false
}

$processTimer = New-Object Windows.Threading.DispatcherTimer
$processTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$processTimer.add_Tick({ Update-TrackedPowerShell })
$processTimer.Start()

$loadProfilesButton.add_Click({
        try {
            if ($null -ne $script:SessionAuthentication) {
                Invoke-CatalogRefresh
                return
            }
            $authentication = Get-AuthenticationConfiguration
            $script:PendingAuthenticationSession = Get-AuthenticationSessionCandidate `
                -Authentication $authentication
            Save-GuiSetting
            Clear-DriverCatalog
            $connectionStatusTextBlock.Text = 'Connexion et chargement en cours...'
            $command = Get-CatalogCommand -Resource Snapshot -Authentication $authentication
            $onSuccess = {
                param($json)
                Show-CatalogResult -Json $json -NotifyReadOnly
            }
            Invoke-TrackedPowerShell `
                -Command $command `
                -Activity 'Connexion et chargement des profils/drivers' `
                -SuccessMessage 'Catalogue WUfB Drivers chargé' `
                -ClientSecret $authentication.ClientSecret `
                -OnSuccess $onSuccess `
                -SuppressOutput
            $authentication.ClientSecret = ''
        }
        catch {
            $script:PendingAuthenticationSession = $null
            $connectionStatusTextBlock.Text = 'Échec de connexion'
            Show-GuiError -Message $_.Exception.Message
        }
    })

$refreshCatalogButton.add_Click({
        try {
            Invoke-CatalogRefresh
        }
        catch {
            $connectionStatusTextBlock.Text = "Échec de l'actualisation"
            $pausedDriversStatusTextBlock.Text = "Échec de l'actualisation"
            Show-GuiError -Message $_.Exception.Message
        }
    })

$refreshPausedDriversButton.add_Click({
        try {
            Invoke-CatalogRefresh
        }
        catch {
            $connectionStatusTextBlock.Text = "Échec de l'actualisation"
            $pausedDriversStatusTextBlock.Text = "Échec de l'actualisation"
            Show-GuiError -Message $_.Exception.Message
        }
    })

$refreshDriverProfilesButton.add_Click({
        try {
            Invoke-CatalogRefresh
        }
        catch {
            $driverProfilesStatusTextBlock.Text = "Échec de l'actualisation"
            Show-GuiError -Message $_.Exception.Message
        }
    })

$driverProfilesComboBox.add_SelectionChanged({
        Show-DriverProfiles
    })

$profilesDataGrid.add_SelectionChanged({
        if ($script:IsBusy) {
            return
        }

        $selectedProfile = $profilesDataGrid.SelectedItem
        if ($null -eq $selectedProfile) {
            return
        }

        $script:SelectedProfile = $selectedProfile
        $script:SelectedDriver = $null
        $selectedProfileTextBlock.Text = [string] $selectedProfile.displayName
        $selectedDriverTextBox.Text = ''
        $profileId = [string] $selectedProfile.id
        $drivers = if ($script:DriverInventories.ContainsKey($profileId)) {
            @($script:DriverInventories[$profileId])
        }
        else {
            @()
        }
        $driversDataGrid.ItemsSource = $drivers
        $statusTextBlock.Text = '{0} driver(s) dans le profil sélectionné' -f $drivers.Count
        Show-TargetControl
    })

$pausedDriversDataGrid.add_SelectionChanged({
        Show-PausedDriverControl
    })

$driversDataGrid.add_SelectionChanged({
        if ($script:IsBusy) {
            return
        }

        $selectedDriver = $driversDataGrid.SelectedItem
        if ($null -eq $selectedDriver) {
            return
        }

        $script:SelectedDriver = $selectedDriver
        $selectedDriverTextBox.Text = '{0} | {1} | {2} | état: {3}' -f
            $selectedDriver.name,
            $selectedDriver.version,
            $selectedDriver.manufacturer,
            $selectedDriver.approvalStatus
        $useSelectedDriverRadioButton.IsChecked = $true
        $driverProfilesComboBox.SelectedValue = [string] $selectedDriver.id
        Show-TargetControl
    })

$useSelectedDriverRadioButton.add_Checked({
        Show-TargetControl
    })

$useManualDriverRadioButton.add_Checked({
        Show-TargetControl
    })

$driverNameTextBox.add_TextChanged({
        Show-TargetControl
    })

$authenticationModeComboBox.add_SelectionChanged({
        if ((Get-SelectedAuthenticationMode) -ne 'ClientSecret') {
            $clientSecretPasswordBox.Password = ''
        }
        Clear-AuthenticationSession
        Show-AuthenticationControl
        Clear-DriverCatalog
    })

$tenantIdTextBox.add_TextChanged({
        if ($null -ne $script:SessionAuthentication -and
            $tenantIdTextBox.Text.Trim() -ne $script:SessionAuthentication.TenantId) {
            Clear-AuthenticationSession
            Clear-DriverCatalog
        }
    })

$clientIdTextBox.add_TextChanged({
        if ($null -ne $script:SessionAuthentication -and
            $clientIdTextBox.Text.Trim() -ne $script:SessionAuthentication.ClientId) {
            Clear-AuthenticationSession
            Clear-DriverCatalog
        }
    })

$clientSecretPasswordBox.add_PasswordChanged({
        if ($null -ne $script:SessionAuthentication -and
            $script:SessionAuthentication.AuthenticationMode -eq 'ClientSecret' -and
            $clientSecretPasswordBox.Password.Length -gt 0) {
            Clear-AuthenticationSession
            Clear-DriverCatalog
        }
        Show-AuthenticationControl
    })

$certificateComboBox.add_SelectionChanged({
        if ($null -ne $script:SessionAuthentication -and
            $script:SessionAuthentication.AuthenticationMode -eq 'Certificate' -and
            [string] $certificateComboBox.SelectedValue -ne
                $script:SessionAuthentication.CertificateThumbprint) {
            Clear-AuthenticationSession
            Clear-DriverCatalog
        }
    })

$refreshCertificatesButton.add_Click({
        $currentThumbprint = [string] $certificateComboBox.SelectedValue
        Read-CertificateList -PreferredThumbprint $currentThumbprint
    })

$simulationButton.add_Click({
        try {
            $configuration = Get-GuiConfiguration
            Save-GuiSetting
            $command = Get-WatchCommand -Configuration $configuration -Simulation
            Invoke-TrackedPowerShell `
                -Command $command `
                -Activity 'Simulation en cours' `
                -SuccessMessage 'Simulation terminée' `
                -ClientSecret $configuration.ClientSecret
            if ($configuration.AuthenticationMode -eq 'ClientSecret') {
                $clientSecretPasswordBox.Password = ''
                $configuration.ClientSecret = ''
            }
        }
        catch {
            $clientSecretPasswordBox.Password = ''
            Show-GuiError -Message $_.Exception.Message
        }
    })

$executeButton.add_Click({
        try {
            $configuration = Get-GuiConfiguration
            $driverList = $configuration.DriverNames -join ', '
            $confirmation = [Windows.MessageBox]::Show(
                $window,
                "Suspendre maintenant le ou les pilotes suivants dans tous les profils WUfB Drivers ?`r`n`r`n$driverList",
                'Confirmer la suspension',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Warning
            )
            if ($confirmation -ne [Windows.MessageBoxResult]::Yes) {
                return
            }

            Save-GuiSetting
            $command = Get-WatchCommand -Configuration $configuration
            $onSuccess = if ($configuration.TargetMode -eq 'Selected') {
                Get-DriverActionCompletion -Configuration $configuration -ApprovalStatus suspended
            }
            else {
                $null
            }
            Invoke-TrackedPowerShell `
                -Command $command `
                -Activity 'Suspension et vérification en cours' `
                -SuccessMessage 'Contrôle terminé avec succès' `
                -ClientSecret $configuration.ClientSecret `
                -OnSuccess $onSuccess
            if ($configuration.AuthenticationMode -eq 'ClientSecret') {
                $clientSecretPasswordBox.Password = ''
                $configuration.ClientSecret = ''
            }
        }
        catch {
            $clientSecretPasswordBox.Password = ''
            Show-GuiError -Message $_.Exception.Message
        }
    })

$approveProfileButton.add_Click({
        Invoke-GuiDriverApproval
    })

$approveAllButton.add_Click({
        Invoke-GuiDriverApproval -AllProfiles
    })

$completePauseButton.add_Click({
        try {
            $completionTarget = $pausedDriversDataGrid.SelectedItem
            $configuration = Get-PausedDriverCompletionConfiguration
            $missingProfiles = [string] $completionTarget.MissingProfiles
            $confirmation = [Windows.MessageBox]::Show(
                $window,
                "Compléter la suspension de '$($completionTarget.Name)' dans les profils suivants ?`r`n`r`n$missingProfiles",
                'Confirmer le complément de suspension',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Warning
            )
            if ($confirmation -ne [Windows.MessageBoxResult]::Yes) {
                return
            }

            $onSuccess = Get-DriverActionCompletion -Configuration $configuration -ApprovalStatus suspended

            $command = Get-WatchCommand -Configuration $configuration
            Invoke-TrackedPowerShell `
                -Command $command `
                -Activity 'Complément de suspension en cours' `
                -SuccessMessage 'Suspension complétée avec succès' `
                -ClientSecret $configuration.ClientSecret `
                -OnSuccess $onSuccess
            if ($configuration.AuthenticationMode -eq 'ClientSecret') {
                $clientSecretPasswordBox.Password = ''
                $configuration.ClientSecret = ''
            }
        }
        catch {
            $clientSecretPasswordBox.Password = ''
            Show-GuiError -Message $_.Exception.Message
        }
    })

$installTaskButton.add_Click({
        try {
            $configuration = Get-GuiConfiguration
            if ($configuration.AuthenticationMode -ne 'Certificate') {
                throw 'La tâche horaire exige le mode Certificat. Sélectionnez ce mode avant de continuer.'
            }
            $confirmation = [Windows.MessageBox]::Show(
                $window,
                "Créer ou remplacer la tâche horaire '$($configuration.TaskName)' pour suspendre ces pilotes dans tous les profils WUfB Drivers ?",
                'Confirmer la tâche planifiée',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Question
            )
            if ($confirmation -ne [Windows.MessageBoxResult]::Yes) {
                return
            }

            Save-GuiSetting
            $command = Get-RegisterTaskCommand -Configuration $configuration
            Invoke-TrackedPowerShell `
                -Command $command `
                -Activity 'Installation de la tâche horaire' `
                -SuccessMessage 'Tâche horaire installée' `
                -Elevated:$( -not (Get-IsAdministrator) )
        }
        catch {
            Show-GuiError -Message $_.Exception.Message
        }
    })

$openLogButton.add_Click({
        try {
            $logPath = if ([string]::IsNullOrWhiteSpace($logPathTextBox.Text)) {
                $defaultLogPath
            }
            else {
                [IO.Path]::GetFullPath($logPathTextBox.Text.Trim())
            }

            if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
                throw "Le journal n'existe pas encore : $logPath"
            }
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $logPath) | Out-Null
        }
        catch {
            Show-GuiError -Message $_.Exception.Message
        }
    })

$closeButton.add_Click({
        $window.Close()
    })

$window.add_Closing({
        param($sender, $eventArgs)
        if ($null -ne $script:ActivePowerShell -or
            ($null -ne $script:ActiveProcess -and -not $script:ActiveProcess.HasExited)) {
            [Windows.MessageBox]::Show(
                $window,
                "Une opération est en cours. Attendez sa fin avant de fermer l'interface.",
                'Opération en cours',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Information
            ) | Out-Null
            $eventArgs.Cancel = $true
        }
    })

Import-GuiSetting
if ($ValidateOnly) {
    $validationConfiguration = [pscustomobject] @{
        DriverNames          = @('Validation Driver')
        DriverIds            = @('validation-driver-id')
        TargetMode           = 'Manual'
        NameMatchMode        = 'Exact'
        Manufacturer         = 'Validation Manufacturer'
        DriverVersion        = '1.0.0'
        ProfileNames         = @()
        ProfileIds           = @()
        AuthenticationMode   = 'Certificate'
        TenantId             = '00000000-0000-0000-0000-000000000000'
        ClientId             = '11111111-1111-1111-1111-111111111111'
        ClientSecret         = ''
        CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'
        TaskName             = 'Validation Task'
        LogPath              = $defaultLogPath
    }
    $certificateValidationCommand = Get-WatchCommand -Configuration $validationConfiguration -Simulation
    $validationConfiguration.ProfileIds = @('new-profile-id')
    $completionValidationCommand = Get-WatchCommand -Configuration $validationConfiguration
    $profileApprovalValidationCommand = Get-WatchCommand -Configuration $validationConfiguration -Action Approve
    $validationConfiguration.ProfileIds = @()
    $allApprovalValidationCommand = Get-WatchCommand -Configuration $validationConfiguration -Action Approve
    $catalogAuthentication = [pscustomobject] @{
        AuthenticationMode   = $validationConfiguration.AuthenticationMode
        TenantId             = $validationConfiguration.TenantId
        ClientId             = $validationConfiguration.ClientId
        ClientSecret         = ''
        CertificateThumbprint = $validationConfiguration.CertificateThumbprint
    }
    $catalogValidationCommand = Get-CatalogCommand `
        -Resource Snapshot `
        -Authentication $catalogAuthentication
    $validationConfiguration.TargetMode = 'Selected'
    $selectedTaskValidationCommand = Get-RegisterTaskCommand -Configuration $validationConfiguration
    $validationConfiguration.TargetMode = 'Manual'
    $validationConfiguration.AuthenticationMode = 'Interactive'
    $validationConfiguration.ClientId = ''
    $validationConfiguration.TenantId = ''
    $interactiveValidationCommand = Get-WatchCommand -Configuration $validationConfiguration
    $validationConfiguration.AuthenticationMode = 'ClientSecret'
    $validationConfiguration.TenantId = '00000000-0000-0000-0000-000000000000'
    $validationConfiguration.ClientId = '11111111-1111-1111-1111-111111111111'
    $validationConfiguration.ClientSecret = 'secret-not-allowed-in-command'
    $secretValidationCommand = Get-WatchCommand -Configuration $validationConfiguration

    $pausedSummaryValidation = @(
        Get-PausedDriverSummary `
            -Profiles @(
                [pscustomobject] @{ id = 'profile-a'; displayName = 'Profile A' },
                [pscustomobject] @{ id = 'profile-b'; displayName = 'Profile B' }
            ) `
            -Inventories @{
                'profile-a' = @(
                    [pscustomobject] @{
                        id             = 'driver-a'
                        name           = 'Validation Driver'
                        version        = '1.0.0'
                        manufacturer   = 'Validation Manufacturer'
                        approvalStatus = 'suspended'
                    }
                )
                'profile-b' = @(
                    [pscustomobject] @{
                        id             = 'driver-a'
                        name           = 'Validation Driver'
                        version        = '1.0.0'
                        manufacturer   = 'Validation Manufacturer'
                        approvalStatus = 'approved'
                    },
                    [pscustomobject] @{
                        id             = 'driver-not-paused'
                        name           = 'Driver Not Paused'
                        version        = '2.0.0'
                        manufacturer   = 'Validation Manufacturer'
                        approvalStatus = 'approved'
                    }
                )
            }
    )

    if ($certificateValidationCommand -notmatch '-WhatIf' -or
        $certificateValidationCommand -notmatch '-AuthenticationMode ''CurrentContext''' -or
        $certificateValidationCommand -notmatch '-KeepGraphConnection' -or
        $completionValidationCommand -notmatch '-ProfileId' -or
        $completionValidationCommand -notmatch 'new-profile-id' -or
        $certificateValidationCommand -notmatch '-Action ''Suspend''' -or
        $profileApprovalValidationCommand -notmatch '-Action ''Approve''' -or
        $profileApprovalValidationCommand -notmatch '-ProfileId' -or
        $allApprovalValidationCommand -notmatch '-Action ''Approve''' -or
        $allApprovalValidationCommand -match '-ProfileId' -or
        $interactiveValidationCommand -notmatch '-AuthenticationMode ''CurrentContext''' -or
        $interactiveValidationCommand -match '-CertificateThumbprint' -or
        $interactiveValidationCommand -match '-TenantId' -or
        $secretValidationCommand -notmatch '-AuthenticationMode ''ClientSecret''' -or
        $secretValidationCommand -match 'secret-not-allowed-in-command' -or
        $catalogValidationCommand -notmatch '-Resource ''Snapshot''' -or
        $catalogValidationCommand -notmatch '-AuthenticationMode ''Certificate''' -or
        $catalogValidationCommand -notmatch '-KeepGraphConnection' -or
        $selectedTaskValidationCommand -notmatch '-DriverId' -or
        $certificateValidationCommand -match '-ProfileId' -or
        $selectedTaskValidationCommand -match '-ProfileId' -or
        $selectedTaskValidationCommand -notmatch '-TaskName' -or
        $pausedSummaryValidation.Count -ne 1 -or
        -not $pausedSummaryValidation[0].NeedsCompletion -or
        $pausedSummaryValidation[0].MissingProfiles -ne 'Profile B' -or
        @($pausedSummaryValidation[0].MissingProfileIds)[0] -ne 'profile-b' -or
        $pausedSummaryValidation[0].AllProfiles -ne 'Profile A, Profile B' -or
        $null -eq $pausedDriversDataGrid -or
        $null -eq $driverProfilesComboBox -or
        $null -eq $driverProfilesDataGrid -or
        $null -eq $refreshDriverProfilesButton -or
        $null -eq $window.FindName('HelpTabItem') -or
        $null -eq $window.FindName('HelpContentPanel') -or
        $null -eq $approveProfileButton -or
        $null -eq $approveAllButton -or
        $null -eq $completePauseButton) {
        throw 'La validation des commandes générées par l''interface a échoué.'
    }

    [pscustomobject] @{
        WindowTitle      = $window.Title
        CertificateCount = $certificateComboBox.Items.Count
        WatchScript      = $watchScriptPath
        RegisterScript   = $registerScriptPath
        CatalogScript    = $catalogScriptPath
        CommandValidation = 'Passed'
        PausedDriverValidation = 'Passed'
    }
    return
}

$driverNameTextBox.Focus() | Out-Null
try {
    $window.ShowDialog() | Out-Null
}
finally {
    $processTimer.Stop()
    Clear-AuthenticationSession
}
