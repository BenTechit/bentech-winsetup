# src/Toolbox/Toolbox.ps1
# The BenTech Toolbox window (toolbox spec 4 and 5): a dark WPF window that replaces the console start screen.
# Ben picks a profile, adjusts the options, the tweaks and the restore point, in English or Hebrew; the right-hand
# column always shows what will happen.
#
# This file holds the window's look: the XAML ($script:ToolboxXaml), the string table the window reads
# (New-ToolboxStringTable, Get-ToolboxString), the window itself (New-ToolboxWindow), the language walk
# (Set-ToolboxLanguage) and the view (Update-ToolboxView), which renders the pure model of SetupPlanner.ps1.
#
# The WPF rules (spec 5.1; the plan's Global Constraints), which every later addition keeps:
#   - The window's state lives in $window.Tag (the plan's "Toolbox model and window state"). Every handler is one
#     line, { Invoke-ToolboxAction -Sender $this }: no GetNewClosure(), no outer variables.
#   - Every .NET call's output goes to $null, so every function returns exactly one value or nothing.
#   - Start is never the default button (IsDefault False, Focusable False) and Esc is unbound: the XAML has no
#     IsCancel, no key bindings, no event attributes and no x:Class.
#   - All colours are hex values in the one <Window.Resources> dictionary; the font sizes are resources there too.
#     Text is Segoe UI, icons are glyphs from "Segoe Fluent Icons, Segoe MDL2 Assets" (so they also show on
#     Windows 10). No image files, nothing downloaded; the "B" logo is drawn.
#   - Every visible text is a TextBlock. Fixed texts carry Tag="t:<key>" and come from the string table; a
#     clickable element carries Tag="a:<Action>:<Value>" (Task 3 reads it). The two kinds never meet on one element.
#   - Hebrew turns the window right-to-left; the machine values and the plan's step titles stay left-to-right.
#   - Nothing here writes to the console (no Write-Host) or sleeps.
#   - ShowDialog() and Dispatcher.InvokeShutdown() are never called here, and no test calls them.
#
# Needs: Toolbox\Strings.ps1 ($script:ToolboxStrings), Toolbox\SetupPlanner.ps1 (Get-SetupProfiles,
# Get-ToolboxPlanLines), Engine\Catalog.ps1 (Get-TweakCatalog, Test-TweakAllowed, Get-RemoteChoice),
# UI\StartScreen.ps1 (ConvertFrom-StateTime, ConvertTo-ScreenText) and WPF (PresentationFramework,
# PresentationCore, WindowsBase), loaded by the caller. The bundle holds every file.

# The window. The XML namespaces live in New-ToolboxParserContext, not here: the text holds no URL at all.
$script:ToolboxXaml = @'
<Window xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="BenTech Toolbox" Width="1000" Height="680" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Topmost="True" FontFamily="Segoe UI" ShowInTaskbar="True" UseLayoutRounding="True">
  <Window.Resources>
    <!-- Colours (toolbox spec 4.2). The first five are the spec's; the others are settled on the screenshots. -->
    <SolidColorBrush x:Key="BgBrush" Color="#1E1E1E"/>
    <SolidColorBrush x:Key="PanelBrush" Color="#252526"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F0F0F0"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#2D7DD2"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#FFC83D"/>
    <SolidColorBrush x:Key="SubtleTextBrush" Color="#B4B4B4"/>
    <SolidColorBrush x:Key="LineBrush" Color="#3C3C3C"/>
    <SolidColorBrush x:Key="TileBrush" Color="#2D2D30"/>
    <SolidColorBrush x:Key="TileHoverBrush" Color="#3E3E42"/>
    <SolidColorBrush x:Key="WarnBackBrush" Color="#3A3214"/>
    <SolidColorBrush x:Key="DangerBackBrush" Color="#5A1E1E"/>
    <SolidColorBrush x:Key="DangerLineBrush" Color="#E04343"/>
    <SolidColorBrush x:Key="SwitchOffBrush" Color="#5A5A5A"/>
    <SolidColorBrush x:Key="DimTextBrush" Color="#8A8A8A"/>
    <SolidColorBrush x:Key="OnAccentBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="AccentHoverBrush" Color="#4A90DC"/>
    <SolidColorBrush x:Key="AccentPressedBrush" Color="#2566AD"/>
    <SolidColorBrush x:Key="CloseHoverBrush" Color="#C42B1C"/>

    <!-- Fonts and sizes. -->
    <FontFamily x:Key="GlyphFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <sys:Double x:Key="BaseFontSize">13</sys:Double>
    <sys:Double x:Key="SmallFontSize">11.5</sys:Double>
    <sys:Double x:Key="TitleFontSize">15</sys:Double>
    <sys:Double x:Key="GlyphFontSize">16</sys:Double>
    <sys:Double x:Key="SmallGlyphFontSize">12</sys:Double>
    <sys:Double x:Key="CaptionGlyphFontSize">10</sys:Double>
    <sys:Double x:Key="MachineGlyphFontSize">20</sys:Double>

    <!-- Text. -->
    <Style x:Key="GlyphStyle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource GlyphFont}"/>
      <Setter Property="FontSize" Value="{StaticResource GlyphFontSize}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="TileGlyphStyle" TargetType="TextBlock" BasedOn="{StaticResource GlyphStyle}">
      <Setter Property="Margin" Value="0,0,7,0"/>
    </Style>
    <Style x:Key="RowLabelStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="{StaticResource SmallFontSize}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Margin" Value="0,8,10,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="SectionTitleStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="{StaticResource SmallFontSize}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
    </Style>
    <Style x:Key="TweakGlyphStyle" TargetType="TextBlock" BasedOn="{StaticResource GlyphStyle}">
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="Margin" Value="0,0,12,0"/>
    </Style>
    <Style x:Key="TweakTitleStyle" TargetType="TextBlock">
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="LineHeight" Value="17"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>
    <Style x:Key="TweakDescStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="{StaticResource SmallFontSize}"/>
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="LineHeight" Value="15"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>
    <Style x:Key="TipTextStyle" TargetType="TextBlock">
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="MaxWidth" Value="420"/>
    </Style>
    <Style x:Key="PlanLineStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="{StaticResource BaseFontSize}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="LineHeight" Value="22"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>

    <!-- Panels. -->
    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
      <Setter Property="CornerRadius" Value="8"/>
    </Style>
    <Style x:Key="TweakRowStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="ChipStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource TileBrush}"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Height" Value="30"/>
    </Style>

    <!-- An option tile: a RadioButton; the chosen one is filled with the accent colour. -->
    <Style x:Key="TileStyle" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Background" Value="{StaticResource TileBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="MinWidth" Value="88"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="{StaticResource OnAccentBrush}"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsChecked" Value="True"/>
                  <Condition Property="IsMouseOver" Value="True"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentHoverBrush}"/>
              </MultiTrigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- EN | HE in the title bar. -->
    <Style x:Key="LangStyle" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="{StaticResource SmallFontSize}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="MinWidth" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileHoverBrush}"/>
                <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter Property="Foreground" Value="{StaticResource OnAccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- A switch: a CheckBox drawn as a Windows 11 toggle, its content beside it. -->
    <Style x:Key="SwitchStyle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Track" Width="40" Height="20" CornerRadius="10" BorderThickness="1" VerticalAlignment="Center"
                      Background="Transparent" BorderBrush="{StaticResource SubtleTextBrush}">
                <Ellipse x:Name="Knob" Width="12" Height="12" Margin="3,0" HorizontalAlignment="Left" VerticalAlignment="Center"
                         Fill="{StaticResource SubtleTextBrush}"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource TextBrush}"/>
                <Setter TargetName="Knob" Property="Fill" Value="{StaticResource TextBrush}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Knob" Property="Fill" Value="{StaticResource OnAccentBrush}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Width" Value="14"/>
                <Setter TargetName="Knob" Property="Height" Value="14"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Buttons. -->
    <Style x:Key="AccentButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource OnAccentBrush}"/>
      <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentPressedBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileBrush}"/>
                <Setter Property="Foreground" Value="{StaticResource DimTextBrush}"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PlainButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CaptionButtonStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="0,7,0,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource CloseHoverBrush}"/>
                <Setter Property="Foreground" Value="{StaticResource OnAccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- A thin dark scroll bar (the content scrolls when the window is clamped to a small screen). -->
    <Style x:Key="ScrollThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="Bd" CornerRadius="3" Background="{StaticResource SwitchOffBrush}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource SubtleTextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollPageStyle" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Margin" Value="0,4,3,12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
              <Track.DecreaseRepeatButton>
                <RepeatButton x:Name="PageDecrease" Style="{StaticResource ScrollPageStyle}" Command="ScrollBar.PageUpCommand"/>
              </Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton>
                <RepeatButton x:Name="PageIncrease" Style="{StaticResource ScrollPageStyle}" Command="ScrollBar.PageDownCommand"/>
              </Track.IncreaseRepeatButton>
              <Track.Thumb>
                <Thumb Style="{StaticResource ScrollThumbStyle}"/>
              </Track.Thumb>
            </Track>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                <Setter TargetName="PageDecrease" Property="Command" Value="ScrollBar.PageLeftCommand"/>
                <Setter TargetName="PageIncrease" Property="Command" Value="ScrollBar.PageRightCommand"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="6"/>
          <Setter Property="MinHeight" Value="6"/>
          <Setter Property="Margin" Value="12,0,12,3"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- The body's scroll bars lie over the content's outer gutter instead of taking room from it, so the layout
         is the same with and without them. -->
    <Style x:Key="OverlayScrollStyle" TargetType="ScrollViewer">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollViewer">
            <Grid Background="{TemplateBinding Background}">
              <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" CanContentScroll="{TemplateBinding CanContentScroll}"/>
              <ScrollBar x:Name="PART_VerticalScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Minimum="0"
                         Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}"
                         Value="{TemplateBinding VerticalOffset}" Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
              <ScrollBar x:Name="PART_HorizontalScrollBar" Orientation="Horizontal" VerticalAlignment="Bottom" Minimum="0"
                         Maximum="{TemplateBinding ScrollableWidth}" ViewportSize="{TemplateBinding ViewportWidth}"
                         Value="{TemplateBinding HorizontalOffset}" Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The tweak descriptions' tooltip. -->
    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="{StaticResource BaseFontSize}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="4" Padding="10,7">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="RootBorder" CornerRadius="8" Background="{StaticResource BgBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1"
          TextElement.FontSize="{StaticResource BaseFontSize}" TextElement.Foreground="{StaticResource TextBrush}" TextOptions.TextFormattingMode="Display">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Title bar: the drawn logo, the title, EN | HE and the close button. The whole bar drags the window. -->
      <Grid x:Name="TitleBar" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
          <Border Width="26" Height="26" CornerRadius="6" Background="{StaticResource AccentBrush}">
            <TextBlock Text="B" FontSize="{StaticResource TitleFontSize}" FontWeight="Bold" Foreground="{StaticResource OnAccentBrush}"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Tag="t:app.title" Margin="10,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
        </StackPanel>
        <Border Grid.Column="1" Background="{StaticResource TileBrush}" CornerRadius="6" Padding="2" Margin="0,0,8,0" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="LangEn" Style="{StaticResource LangStyle}" Tag="a:Language:en"><TextBlock Text="EN"/></RadioButton>
            <RadioButton x:Name="LangHe" Style="{StaticResource LangStyle}" Tag="a:Language:he"><TextBlock Text="HE"/></RadioButton>
          </StackPanel>
        </Border>
        <Button x:Name="CloseButton" Grid.Column="2" Style="{StaticResource CaptionButtonStyle}" Tag="a:Cancel:">
          <TextBlock Style="{StaticResource GlyphStyle}" FontSize="{StaticResource CaptionGlyphFontSize}" Text="&#xE711;"/>
        </Button>
      </Grid>

      <!-- Body: nav, options, plan. It all scrolls when the window is clamped to a small screen (spec 4.1). -->
      <ScrollViewer x:Name="ContentScroll" Grid.Row="1" Style="{StaticResource OverlayScrollStyle}" HorizontalScrollBarVisibility="Auto"
                    VerticalScrollBarVisibility="Auto" Focusable="False">
        <Grid MinWidth="960" Width="{Binding ViewportWidth, ElementName=ContentScroll}">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="170"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="270"/>
          </Grid.ColumnDefinitions>

          <!-- Left nav: one entry today; a later tool adds one entry and one page. -->
          <DockPanel LastChildFill="False" Margin="8,6,8,14">
            <Border x:Name="NavSetup" DockPanel.Dock="Top" Height="38" CornerRadius="6" Background="{StaticResource TileBrush}">
              <Grid>
                <Border Width="3" Height="16" CornerRadius="2" Background="{StaticResource AccentBrush}" HorizontalAlignment="Left"/>
                <StackPanel Orientation="Horizontal" Margin="12,0,6,0" VerticalAlignment="Center">
                  <TextBlock Style="{StaticResource GlyphStyle}" Foreground="{StaticResource AccentBrush}" Text="&#xE7F4;"/>
                  <TextBlock Tag="t:nav.setup" Margin="10,0,0,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>
            </Border>
            <TextBlock x:Name="VersionText" DockPanel.Dock="Bottom" Margin="14,0,0,0" HorizontalAlignment="Left" FlowDirection="LeftToRight"
                       FontSize="{StaticResource SmallFontSize}" Foreground="{StaticResource DimTextBrush}"/>
          </DockPanel>

          <!-- Center: banners, the machine card and the options. -->
          <StackPanel Grid.Column="1" Margin="4,6,14,12">
            <Border x:Name="AdminBanner" Visibility="Collapsed" Background="{StaticResource DangerBackBrush}" BorderBrush="{StaticResource DangerLineBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Style="{StaticResource GlyphStyle}" VerticalAlignment="Top" Margin="0,1,10,0" Text="&#xE730;"/>
                <TextBlock Grid.Column="1" Tag="t:warn.adminProtection" TextWrapping="Wrap" LineHeight="18" LineStackingStrategy="BlockLineHeight"/>
              </Grid>
            </Border>

            <Border Style="{StaticResource CardStyle}" Padding="10,7,10,7">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="38" Height="38" CornerRadius="6" Background="{StaticResource TileBrush}">
                  <TextBlock x:Name="MachineGlyph" Style="{StaticResource GlyphStyle}" FontSize="{StaticResource MachineGlyphFontSize}"
                             Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
                  <TextBlock x:Name="MachineModel" FlowDirection="LeftToRight" HorizontalAlignment="Left" FontSize="{StaticResource TitleFontSize}"
                             FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                  <StackPanel Orientation="Horizontal" Margin="0,1,0,0">
                    <TextBlock Tag="t:machine.serial" Foreground="{StaticResource SubtleTextBrush}"/>
                    <TextBlock x:Name="MachineSerial" FlowDirection="LeftToRight" Margin="6,0,0,0"/>
                    <Ellipse Width="3" Height="3" Margin="10,0" VerticalAlignment="Center" Fill="{StaticResource DimTextBrush}"/>
                    <TextBlock Tag="t:machine.newName" Foreground="{StaticResource SubtleTextBrush}"/>
                    <TextBlock x:Name="MachineNewName" FlowDirection="LeftToRight" Margin="6,0,0,0" FontWeight="SemiBold"/>
                  </StackPanel>
                </StackPanel>
                <Border x:Name="PowerChip" Grid.Column="2" CornerRadius="12" Background="{StaticResource TileBrush}" Padding="10,4" VerticalAlignment="Center">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="MachinePowerGlyph" Style="{StaticResource GlyphStyle}" FontSize="{StaticResource SmallGlyphFontSize}"/>
                    <TextBlock x:Name="MachinePower" Margin="6,0,0,0" FontSize="{StaticResource SmallFontSize}" VerticalAlignment="Center"/>
                  </StackPanel>
                </Border>
              </Grid>
            </Border>

            <Border x:Name="WarnPanel" Visibility="Collapsed" Background="{StaticResource WarnBackBrush}" CornerRadius="6" Padding="12,5" Margin="0,8,0,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Style="{StaticResource GlyphStyle}" VerticalAlignment="Top" Margin="0,1,10,0" Foreground="{StaticResource WarnBrush}" Text="&#xE7BA;"/>
                <TextBlock x:Name="WarnText" Grid.Column="1" Foreground="{StaticResource WarnBrush}" TextWrapping="Wrap" LineHeight="17" LineStackingStrategy="BlockLineHeight"/>
              </Grid>
            </Border>

            <Grid Margin="0,12,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="76"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>

              <TextBlock Grid.Row="0" Style="{StaticResource RowLabelStyle}" Tag="t:row.profile"/>
              <WrapPanel x:Name="ProfilePanel" Grid.Row="0" Grid.Column="1"/>

              <TextBlock Grid.Row="1" Style="{StaticResource RowLabelStyle}" Tag="t:row.type"/>
              <WrapPanel Grid.Row="1" Grid.Column="1">
                <RadioButton x:Name="TypeLaptop" Style="{StaticResource TileStyle}" Tag="a:Mode:LAPTOP">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE7F8;"/><TextBlock Tag="t:type.laptop" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="TypeDesktop" Style="{StaticResource TileStyle}" Tag="a:Mode:DESKTOP">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE7F4;"/><TextBlock Tag="t:type.desktop" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
              </WrapPanel>

              <TextBlock Grid.Row="2" Style="{StaticResource RowLabelStyle}" Tag="t:row.office"/>
              <WrapPanel Grid.Row="2" Grid.Column="1">
                <RadioButton x:Name="OfficeCraft" Style="{StaticResource TileStyle}" Tag="a:Office:CRAFT">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE8A5;"/><TextBlock Tag="t:office.craft" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="OfficeBusiness" Style="{StaticResource TileStyle}" Tag="a:Office:BUSINESS">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE821;"/><TextBlock Tag="t:office.business" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="OfficeHome" Style="{StaticResource TileStyle}" Tag="a:Office:HOME">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE80F;"/><TextBlock Tag="t:office.home" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="OfficeOff" Style="{StaticResource TileStyle}" Tag="a:Office:OFF">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE711;"/><TextBlock Tag="t:office.off" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
              </WrapPanel>

              <TextBlock Grid.Row="3" Style="{StaticResource RowLabelStyle}" Tag="t:row.remote"/>
              <StackPanel Grid.Row="3" Grid.Column="1">
                <WrapPanel>
                  <RadioButton x:Name="RemoteAnyDesk" Style="{StaticResource TileStyle}" Tag="a:Remote:ANYDESK">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE703;"/><TextBlock Tag="t:remote.anydesk" VerticalAlignment="Center"/></StackPanel>
                  </RadioButton>
                  <RadioButton x:Name="RemoteScreenConnect" Style="{StaticResource TileStyle}" Tag="a:Remote:SCREENCONNECT">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE7EF;"/><TextBlock Tag="t:remote.screenconnect" VerticalAlignment="Center"/></StackPanel>
                  </RadioButton>
                  <RadioButton x:Name="RemoteBoth" Style="{StaticResource TileStyle}" Tag="a:Remote:BOTH">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE71D;"/><TextBlock Tag="t:remote.both" VerticalAlignment="Center"/></StackPanel>
                  </RadioButton>
                </WrapPanel>
                <Border x:Name="ScreenConnectWarn" Visibility="Collapsed" Background="{StaticResource WarnBackBrush}" CornerRadius="6" Padding="10,5" Margin="0,0,6,6">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Style="{StaticResource GlyphStyle}" FontSize="{StaticResource SmallGlyphFontSize}" Foreground="{StaticResource WarnBrush}" Margin="0,0,8,0" Text="&#xE7BA;"/>
                    <TextBlock Grid.Column="1" Tag="t:warn.screenConnect" FontSize="{StaticResource SmallFontSize}" Foreground="{StaticResource WarnBrush}" TextWrapping="Wrap"/>
                  </Grid>
                </Border>
              </StackPanel>

              <TextBlock Grid.Row="4" Style="{StaticResource RowLabelStyle}" Tag="t:row.apps"/>
              <WrapPanel Grid.Row="4" Grid.Column="1">
                <Border Style="{StaticResource ChipStyle}" Margin="0,0,18,6">
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Style="{StaticResource TileGlyphStyle}" Foreground="{StaticResource AccentBrush}" Text="&#xE73E;"/>
                    <TextBlock Tag="t:apps.chrome" VerticalAlignment="Center"/>
                  </StackPanel>
                </Border>
                <CheckBox x:Name="SevenZipSwitch" Style="{StaticResource SwitchStyle}" Tag="a:SevenZip:" Height="30" Margin="0,0,0,6">
                  <TextBlock Tag="t:apps.sevenZip" FlowDirection="LeftToRight"/>
                </CheckBox>
              </WrapPanel>

              <TextBlock Grid.Row="5" Style="{StaticResource RowLabelStyle}" Tag="t:row.tweaks" Margin="0,11,10,0"/>
              <StackPanel x:Name="TweakPanel" Grid.Row="5" Grid.Column="1" Margin="0,0,0,4"/>

              <TextBlock Grid.Row="6" Style="{StaticResource RowLabelStyle}" Tag="t:row.restore" Margin="0,11,10,0"/>
              <Border Grid.Row="6" Grid.Column="1" Style="{StaticResource TweakRowStyle}" Margin="0">
                <CheckBox x:Name="RestoreSwitch" Style="{StaticResource SwitchStyle}" Tag="a:RestorePoint:">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource TweakGlyphStyle}" Text="&#xE777;"/>
                    <TextBlock Tag="t:restore.label" VerticalAlignment="Center"/>
                  </StackPanel>
                </CheckBox>
              </Border>
            </Grid>
          </StackPanel>

          <!-- Right: what will happen, Cancel and Start. As high as the visible area, so Start stays in view. -->
          <Border Grid.Column="2" VerticalAlignment="Top" Padding="0,6,12,12" Height="{Binding ViewportHeight, ElementName=ContentScroll}">
            <Border Style="{StaticResource CardStyle}">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionTitleStyle}" Tag="t:plan.title" Margin="16,14,16,10"/>
                <Grid DockPanel.Dock="Bottom" Margin="16,10,16,16">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Button x:Name="CancelButton" Style="{StaticResource PlainButtonStyle}" Tag="a:Cancel:" MinWidth="88" Margin="0,0,8,0">
                    <TextBlock Tag="t:button.cancel"/>
                  </Button>
                  <Button x:Name="StartButton" Grid.Column="1" Style="{StaticResource AccentButtonStyle}" Tag="a:Start:" IsDefault="False" Focusable="False">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource GlyphStyle}" FontSize="{StaticResource SmallGlyphFontSize}" Margin="0,0,8,0" Text="&#xE768;"/>
                      <TextBlock Tag="t:button.start" FontWeight="Bold" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Button>
                </Grid>
                <StackPanel x:Name="PlanList" Margin="16,0,16,0" ClipToBounds="True"/>
              </DockPanel>
            </Border>
          </Border>
        </Grid>
      </ScrollViewer>
    </Grid>
  </Border>
</Window>
'@

# The window that is open, for the dispatcher backstop only (Task 3): the dispatcher's event has no window.
$script:ToolboxOpenWindow = $null

function New-ToolboxStringTable {
  <#
  .SYNOPSIS
    The window's string table: @{ en = hashtable; he = hashtable }, the same keys in both. Never throws.
  .DESCRIPTION
    A copy of $script:ToolboxStrings plus the keys built from config.json: profile.<id> (the profile's name),
    tweak.<id>.title and tweak.<id>.desc (Get-SetupProfiles, Get-TweakCatalog). A missing Hebrew text takes the
    English one.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param([AllowNull()]$Config)

  $en = @{}
  $he = @{}
  foreach ($key in $script:ToolboxStrings.en.Keys) { $en[$key] = $script:ToolboxStrings.en[$key] }
  foreach ($key in $script:ToolboxStrings.he.Keys) { $he[$key] = $script:ToolboxStrings.he[$key] }

  $fromConfig = New-Object System.Collections.Generic.List[object]
  foreach ($p in @(Get-SetupProfiles -Config $Config)) { $fromConfig.Add(@("profile.$($p.Id)", $p.Name)) }
  foreach ($t in @(Get-TweakCatalog -Config $Config)) {
    $fromConfig.Add(@("tweak.$($t.Id).title", $t.Title))
    $fromConfig.Add(@("tweak.$($t.Id).desc", $t.Description))
  }
  foreach ($entry in $fromConfig) {
    $key = $entry[0]; $text = $entry[1]
    $en[$key] = [string]$text.en
    $he[$key] = $(if ([string]::IsNullOrWhiteSpace([string]$text.he)) { [string]$text.en } else { [string]$text.he })
  }
  return @{ en = $en; he = $he }
}

function Get-ToolboxString {
  <#
  .SYNOPSIS
    One text of the string table in a language, formatted with -Arguments. Never throws.
  .DESCRIPTION
    The language's text, else the English one, else the key itself (so a missing key shows on screen instead of
    an empty space). A text that does not format with the arguments is returned unformatted.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowNull()][hashtable]$Table,
    [AllowNull()][AllowEmptyString()][string]$Language,
    [AllowNull()][AllowEmptyString()][string]$Key,
    [AllowNull()][object[]]$Arguments
  )

  $text = [string]$Key
  try {
    if ($null -ne $Table -and -not [string]::IsNullOrEmpty($Key)) {
      foreach ($lang in @($Language, 'en')) {
        if ([string]::IsNullOrEmpty($lang)) { continue }
        $part = $Table[$lang]
        if ($part -is [System.Collections.IDictionary] -and $part.Contains($Key) -and -not [string]::IsNullOrEmpty([string]$part[$Key])) {
          $text = [string]$part[$Key]
          break
        }
      }
    }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) { $text = $text -f $Arguments }
  } catch {
    # Best effort: the text as found so far (a bad format string must never break the window).
  }
  return $text
}

function New-ToolboxParserContext {
  # Private. The XAML parser context: the WPF presentation namespace as the default one and the XAML language
  # namespace as x:, so $script:ToolboxXaml itself holds no URL (spec 4.2: nothing is downloaded).
  [CmdletBinding()]
  [OutputType([System.Windows.Markup.ParserContext])]
  param()

  $context = New-Object System.Windows.Markup.ParserContext
  $context.XmlnsDictionary.Add('', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
  $context.XmlnsDictionary.Add('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
  return $context
}

function ConvertTo-ToolboxGlyph {
  # Private. A config icon code ('E765') as its glyph character, or '' when it is not a hex code in the Private
  # Use Area the icon fonts use (U+E000-U+F8FF). Never throws.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowNull()][AllowEmptyString()][string]$Code)

  $value = 0
  if ([int]::TryParse([string]$Code, [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
      $value -ge 0xE000 -and $value -le 0xF8FF) {
    return [string][char]$value
  }
  return ''
}

function New-ToolboxTextBlock {
  # Private. A TextBlock with a style from the window's resources (or none) and a Tag (t:<key>, or nothing).
  [CmdletBinding()]
  [OutputType([System.Windows.Controls.TextBlock])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [AllowEmptyString()][string]$Style = '',
    [AllowEmptyString()][string]$Tag = ''
  )

  $block = New-Object System.Windows.Controls.TextBlock
  if ($Style -ne '') { $block.Style = $Window.FindResource($Style) }
  if ($Tag -ne '') { $block.Tag = $Tag }
  return $block
}

function New-ToolboxTweakRow {
  # Private. One tweak row (toolbox spec 4.1): a switch, the tweak's icon, its title and, below it, its description
  # (trimmed), the whole row clickable; the full description is in the row's tooltip. Returns @{ Row; Switch }.
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][hashtable]$Tweak
  )

  $id = $Tweak.Id
  $glyph = New-ToolboxTextBlock -Window $Window -Style 'TweakGlyphStyle'
  $glyph.Text = ConvertTo-ToolboxGlyph -Code $Tweak.Icon
  [System.Windows.Controls.DockPanel]::SetDock($glyph, [System.Windows.Controls.Dock]::Left)

  $texts = New-Object System.Windows.Controls.StackPanel
  $texts.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $null = $texts.Children.Add((New-ToolboxTextBlock -Window $Window -Style 'TweakTitleStyle' -Tag "t:tweak.$id.title"))
  $null = $texts.Children.Add((New-ToolboxTextBlock -Window $Window -Style 'TweakDescStyle' -Tag "t:tweak.$id.desc"))

  $content = New-Object System.Windows.Controls.DockPanel
  $null = $content.Children.Add($glyph)
  $null = $content.Children.Add($texts)

  $switch = New-Object System.Windows.Controls.CheckBox
  $switch.Style = $Window.FindResource('SwitchStyle')
  $switch.Tag = "a:Tweak:$id"
  $switch.Content = $content

  $row = New-Object System.Windows.Controls.Border
  $row.Style = $Window.FindResource('TweakRowStyle')
  $row.Child = $switch
  $row.ToolTip = New-ToolboxTextBlock -Window $Window -Style 'TipTextStyle' -Tag "t:tweak.$id.desc"
  return @{ Row = $row; Switch = $switch }
}

function New-ToolboxWindow {
  <#
  .SYNOPSIS
    Builds the toolbox window from $script:ToolboxXaml and renders the model once. Returns the Window; shows nothing.
  .DESCRIPTION
    Adds one profile tile per Get-SetupProfiles entry to ProfilePanel and one tweak row per Get-TweakCatalog entry to
    TweakPanel (Update-ToolboxView hides the rows the rules rule out), fills the machine values once (shown as
    read, left-to-right), puts the window state in Tag (the plan's "Toolbox model and window state": Outcome,
    Choices and Error $null, Closing $false, Timer $null) and calls Update-ToolboxView. No handlers (Task 3).
    -ReadOnAC is what the power timer will call (Task 3).
  #>
  [CmdletBinding()]
  [OutputType([System.Windows.Window])]
  param(
    [Parameter(Mandatory)][hashtable]$Model,
    [Parameter(Mandatory)][hashtable]$Machine,
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
    [scriptblock]$ReadOnAC = { Test-OnACPower }
  )

  $window = [System.Windows.Markup.XamlReader]::Parse($script:ToolboxXaml, (New-ToolboxParserContext))

  $tiles = @{}
  $profilePanel = $window.FindName('ProfilePanel')
  foreach ($p in @(Get-SetupProfiles -Config $Config)) {
    $tile = New-Object System.Windows.Controls.RadioButton
    $tile.Style = $window.FindResource('TileStyle')
    $tile.Tag = "a:Profile:$($p.Id)"
    $tile.Content = New-ToolboxTextBlock -Window $window -Tag "t:profile.$($p.Id)"
    $null = $profilePanel.Children.Add($tile)
    $tiles[$p.Id] = $tile
  }

  $rows = @{}
  $tweakPanel = $window.FindName('TweakPanel')
  foreach ($t in @(Get-TweakCatalog -Config $Config)) {
    $row = New-ToolboxTweakRow -Window $window -Tweak $t
    $null = $tweakPanel.Children.Add($row.Row)
    $rows[$t.Id] = $row
  }

  # The machine values, once: as read (no ASCII folding), always left-to-right.
  $friendly = if ([string]::IsNullOrWhiteSpace([string]$Machine['FriendlyModel'])) { $Machine['Model'] } else { $Machine['FriendlyModel'] }
  $window.FindName('MachineModel').Text = ('{0} {1}' -f $Machine['Manufacturer'], $friendly).Trim()
  $window.FindName('MachineSerial').Text = [string]$Machine['Serial']
  $window.FindName('MachineNewName').Text = [string]$Machine['NewName']
  $window.FindName('MachineGlyph').Text = $(if ($Machine['IsLaptop'] -eq $true) { [string][char]0xE7F8 } else { [string][char]0xE7F4 })
  $window.FindName('VersionText').Text = $(if ($Version -match '^[vV]' -or $Version -eq '') { $Version } else { 'v' + $Version })

  $window.Tag = @{
    Model = $Model; Machine = $Machine; Config = $Config; Version = $Version
    Strings = (New-ToolboxStringTable -Config $Config)
    ProfileTiles = $tiles; TweakRows = $rows
    ReadOnAC = $ReadOnAC; Timer = $null
    Outcome = $null; Choices = $null; Error = $null; Closing = $false
  }
  Update-ToolboxView -Window $window
  return $window
}

function Set-ToolboxLanguage {
  <#
  .SYNOPSIS
    Puts every tagged text into the model's language and turns the window right-to-left for Hebrew (spec 4.3).
  .DESCRIPTION
    Walks the logical tree from the window (and each element's ToolTip when that is an element, which is outside
    the tree) and sets TextBlock.Text for every Tag that starts 't:'. Window.FlowDirection is RightToLeft for 'he',
    else LeftToRight; the machine values and the plan rows set LeftToRight themselves. A tooltip follows the
    window's direction (it is not in the tree, so it cannot inherit it).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $language = [string]$state.Model.Language
  $direction = if ($language -eq 'he') { [System.Windows.FlowDirection]::RightToLeft } else { [System.Windows.FlowDirection]::LeftToRight }
  $Window.FlowDirection = $direction

  $pending = New-Object System.Collections.Stack
  $pending.Push($Window)
  while ($pending.Count -gt 0) {
    $node = $pending.Pop()
    if ($node -is [System.Windows.Controls.TextBlock] -and $node.Tag -is [string] -and $node.Tag.StartsWith('t:')) {
      $node.Text = Get-ToolboxString -Table $state.Strings -Language $language -Key $node.Tag.Substring(2)
    }
    if ($node -is [System.Windows.FrameworkElement] -and $node.ToolTip -is [System.Windows.FrameworkElement]) {
      $node.ToolTip.FlowDirection = $direction
      $pending.Push($node.ToolTip)
    }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
      if ($child -is [System.Windows.DependencyObject]) { $pending.Push($child) }
    }
  }
}

function Get-ToolboxDigitIndent {
  # Private. How much wider a digit is than a space in the plan rows' font: a row numbered 1 to 9 (' 1  ...') is
  # moved in by this much, so its number and title line up with the rows numbered 10 and up. The row's Text stays
  # exactly '{0,2}  {1}'. Never throws (0 when it cannot be measured).
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [Parameter(Mandatory)][System.Windows.Window]$Window,
    [Parameter(Mandatory)][double]$FontSize
  )

  try {
    $typeface = New-Object System.Windows.Media.Typeface($Window.FontFamily, [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
    $widths = @(foreach ($text in '0', ' ') {
      [System.Windows.Media.FormattedText]::new($text, [Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight, $typeface, $FontSize,
        [System.Windows.Media.Brushes]::Black, $null, [System.Windows.Media.TextFormattingMode]::Display, 1.0).WidthIncludingTrailingWhitespace
    })
    return [double][math]::Max(0, $widths[0] - $widths[1])
  } catch {
    return [double]0
  }
}

function Update-ToolboxView {
  <#
  .SYNOPSIS
    Renders Tag.Model into the window (spec 4.1). Returns nothing.
  .DESCRIPTION
    The language (Set-ToolboxLanguage); every tile's IsChecked (profiles, Type, Office, Remote, EN | HE) and both
    switches; each tweak row's visibility (Test-TweakAllowed) and switch; the ScreenConnect reminder (Remote is not
    ANYDESK); the yellow banner, one line per warning (not fresh, the previous run as dd/MM/yyyy HH:mm and its
    colour, on battery), collapsed when there is none; the red Administrator-protection banner and Start
    (disabled when protection is On); the power chip; the plan column, rebuilt from Get-ToolboxPlanLines. The
    machine values are New-ToolboxWindow's, set once.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][System.Windows.Window]$Window)

  $state = $Window.Tag
  $model = $state.Model
  $choices = $model.Choices
  $language = [string]$model.Language
  $visible = [System.Windows.Visibility]::Visible
  $collapsed = [System.Windows.Visibility]::Collapsed

  Set-ToolboxLanguage -Window $Window

  foreach ($id in @($state.ProfileTiles.Keys)) { $state.ProfileTiles[$id].IsChecked = ([string]$choices['Profile'] -ceq $id) }
  $remote = Get-RemoteChoice -Choices $choices
  $office = ([string]$choices['Office']).ToUpperInvariant()
  $checks = @{
    TypeLaptop = ($choices['Mode'] -eq 'LAPTOP'); TypeDesktop = ($choices['Mode'] -eq 'DESKTOP')
    OfficeCraft = ($office -eq 'CRAFT'); OfficeBusiness = ($office -eq 'BUSINESS'); OfficeHome = ($office -eq 'HOME'); OfficeOff = ($office -eq 'OFF')
    RemoteAnyDesk = ($remote -eq 'ANYDESK'); RemoteScreenConnect = ($remote -eq 'SCREENCONNECT'); RemoteBoth = ($remote -eq 'BOTH')
    SevenZipSwitch = ($choices['SevenZip'] -eq $true); RestoreSwitch = ($choices['RestorePoint'] -eq $true)
    LangEn = ($language -ne 'he'); LangHe = ($language -eq 'he')
  }
  foreach ($name in $checks.Keys) { $Window.FindName($name).IsChecked = $checks[$name] }

  $selected = @($choices['Tweaks'] | ForEach-Object { [string]$_ })
  foreach ($tweak in @(Get-TweakCatalog -Config $state.Config)) {
    $row = $state.TweakRows[$tweak.Id]
    if ($null -eq $row) { continue }
    $row.Row.Visibility = $(if (Test-TweakAllowed -Tweak $tweak -Choices $choices -Machine $state.Machine) { $visible } else { $collapsed })
    $row.Switch.IsChecked = ($selected -ccontains $tweak.Id)
  }

  $Window.FindName('ScreenConnectWarn').Visibility = $(if ($remote -ne 'ANYDESK') { $visible } else { $collapsed })

  $warnings = New-Object System.Collections.Generic.List[string]
  if ($model.IsFresh -ne $true) { $warnings.Add((Get-ToolboxString -Table $state.Strings -Language $language -Key 'warn.notFresh' -Arguments @($model.MaxAgeDays))) }
  if ($null -ne $model.Previous) {
    $started = ConvertFrom-StateTime $model.Previous['StartedAt']
    $when = if ($null -ne $started) { $started.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { 'unknown date' }
    $color = ConvertTo-ScreenText $model.Previous['Color']
    if ($color -eq '') { $color = 'unfinished' }
    $warnings.Add((Get-ToolboxString -Table $state.Strings -Language $language -Key 'warn.previous' -Arguments @($when, $color)))
  }
  if ($model.OnAC -ne $true) { $warnings.Add((Get-ToolboxString -Table $state.Strings -Language $language -Key 'warn.battery')) }
  $Window.FindName('WarnText').Text = ($warnings -join "`n")
  $Window.FindName('WarnPanel').Visibility = $(if ($warnings.Count -gt 0) { $visible } else { $collapsed })

  $blocked = ($model.AdminProtection -eq 'On')
  $Window.FindName('AdminBanner').Visibility = $(if ($blocked) { $visible } else { $collapsed })
  $Window.FindName('StartButton').IsEnabled = (-not $blocked)

  $onAC = ($model.OnAC -eq $true)
  $Window.FindName('MachinePower').Text = Get-ToolboxString -Table $state.Strings -Language $language -Key $(if ($onAC) { 'power.ac' } else { 'power.battery' })
  $Window.FindName('MachinePowerGlyph').Text = $(if ($onAC) { [string][char]0xE83E } else { [string][char]0xE83F })
  [System.Windows.Documents.TextElement]::SetForeground($Window.FindName('PowerChip'), $Window.FindResource($(if ($onAC) { 'SubtleTextBrush' } else { 'WarnBrush' })))

  $plan = $Window.FindName('PlanList')
  $plan.Children.Clear()
  $lineStyle = $Window.FindResource('PlanLineStyle')
  $numberBrush = $Window.FindResource('DimTextBrush')
  $indent = Get-ToolboxDigitIndent -Window $Window -FontSize ([double]$Window.FindResource('BaseFontSize'))
  foreach ($line in @(Get-ToolboxPlanLines -Model $model -Machine $state.Machine -Config $state.Config)) {
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Style = $lineStyle
    $block.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
    $block.Text = $line
    if ($line.StartsWith(' ')) { $block.Margin = New-Object System.Windows.Thickness($indent, 0, 0, 0) }
    # The step number in a dimmer colour; the text itself stays exactly the line.
    $number = New-Object System.Windows.Media.TextEffect
    $number.PositionStart = 0
    $number.PositionCount = 2
    $number.Foreground = $numberBrush
    $block.TextEffects = New-Object System.Windows.Media.TextEffectCollection
    $null = $block.TextEffects.Add($number)
    $null = $plan.Children.Add($block)
  }
}
