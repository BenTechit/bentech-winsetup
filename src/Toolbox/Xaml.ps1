# src/Toolbox/Xaml.ps1
# The BenTech Toolbox window as XAML (toolbox spec 4.1-4.2; the plan's "XAML contract"). Toolbox.ps1 parses it
# (New-ToolboxWindow) and renders the model into it; this file is data only.
#
# Kept apart from Toolbox.ps1 so the window's logic stays readable. The rules it keeps:
#   - ASCII only (glyphs are written as &#xE7F8; entities). No x:Class, no event attributes, no IsCancel, no key
#     bindings: Start is never the default button (IsDefault False, Focusable False) and Esc is unbound.
#   - Every colour is a hex value in the one <Window.Resources> dictionary; the font sizes are resources there too.
#     Text is Segoe UI, icons are glyphs from "Segoe Fluent Icons, Segoe MDL2 Assets". No image, nothing downloaded.
#   - Every visible text is a TextBlock. Fixed texts carry Tag="t:<key>" (the string table, Strings.ps1); a
#     clickable element carries Tag="a:<Action>:<Value>". The two kinds never meet on one element.
#   - The XML namespaces are not written here (the text holds no URL at all): New-ToolboxParserContext
#     (Toolbox.ps1) supplies the WPF presentation namespace as the default one and the XAML namespace as x:.
#
# Two pages share the window (repair plan, "XAML contract additions"): the left nav's NavSetup and NavRepair switch
# them. The centre column (CenterPanel) holds the shared machine card, the setup page's AdminBanner, WarnPanel and
# SetupOptions, and the Repair & diagnostics page's RepairCenter (the safety strip, the tiles, the complaint box); the
# right column holds SetupRight (what will happen) and RepairRight (what it does, the confirmation, the run or the
# result: one panel at a time). RepairPage.ps1 (Update-RepairView) shows the page the model names.
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
    <!-- Repair & diagnostics: the green and red of the strip, the tiles' state and the findings (CRIT CritBrush, WARN
         WarnBrush, INFO DimTextBrush). Starting values of the repair plan, settled on the screenshots. -->
    <SolidColorBrush x:Key="OkBrush" Color="#4CAF50"/>
    <SolidColorBrush x:Key="OkBackBrush" Color="#1E3A24"/>
    <SolidColorBrush x:Key="CritBrush" Color="#E04343"/>

    <!-- Fonts and sizes. -->
    <FontFamily x:Key="GlyphFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="MonoFont">Consolas</FontFamily>
    <sys:Double x:Key="BaseFontSize">13</sys:Double>
    <sys:Double x:Key="SmallFontSize">11.5</sys:Double>
    <sys:Double x:Key="TitleFontSize">15</sys:Double>
    <sys:Double x:Key="GlyphFontSize">16</sys:Double>
    <sys:Double x:Key="SmallGlyphFontSize">12</sys:Double>
    <sys:Double x:Key="CaptionGlyphFontSize">10</sys:Double>
    <sys:Double x:Key="MachineGlyphFontSize">20</sys:Double>
    <sys:Double x:Key="ChipGlyphFontSize">14</sys:Double>
    <sys:Double x:Key="RepairTileGlyphFontSize">20</sys:Double>
    <sys:Double x:Key="LogFontSize">11</sys:Double>

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

    <!-- The left nav: a RadioButton per page. The chosen one is filled, with the accent bar and a semi-bold name; its
         glyph is the accent colour (the view sets the glyphs' colour: NavSetupGlyph, NavRepairGlyph). -->
    <Style x:Key="NavStyle" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="MinHeight" Value="38"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <Grid>
                <Border x:Name="Bar" Width="3" Height="16" CornerRadius="2" Background="{StaticResource AccentBrush}" HorizontalAlignment="Left" Visibility="Hidden"/>
                <ContentPresenter Margin="12,4,6,4" HorizontalAlignment="Left" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileBrush}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileBrush}"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavGlyphStyle" TargetType="TextBlock" BasedOn="{StaticResource GlyphStyle}">
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>

    <!-- Repair & diagnostics: a chip of the safety strip (its colours are the view's), a small button beside the chips. -->
    <Style x:Key="StripChipStyle" TargetType="Border" BasedOn="{StaticResource ChipStyle}">
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Padding" Value="9,0"/>
    </Style>
    <Style x:Key="ChipGlyphStyle" TargetType="TextBlock" BasedOn="{StaticResource GlyphStyle}">
      <Setter Property="FontSize" Value="{StaticResource ChipGlyphFontSize}"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
    </Style>
    <Style x:Key="SmallButtonStyle" TargetType="Button" BasedOn="{StaticResource PlainButtonStyle}">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
    </Style>

    <!-- An action tile: a Button with a glyph, a title and one line (at most two when it wraps). A disabled tile keeps
         its tooltip (the reason) and fades; the view outlines the selected one (BorderBrush). -->
    <Style x:Key="RepairTileStyle" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Background" Value="{StaticResource TileBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="Height" Value="52"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource TileBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="RepairTileGlyphStyle" TargetType="TextBlock" BasedOn="{StaticResource GlyphStyle}">
      <Setter Property="FontSize" Value="{StaticResource RepairTileGlyphFontSize}"/>
      <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="TileTitleStyle" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="LineHeight" Value="17"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>
    <Style x:Key="TileLineStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="{StaticResource SmallFontSize}"/>
      <Setter Property="Foreground" Value="{StaticResource SubtleTextBrush}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="LineHeight" Value="15"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
      <Setter Property="MaxHeight" Value="30"/>
    </Style>

    <!-- A text box (the customer complaint, YES): dark, the accent line while it has the focus. -->
    <Style x:Key="InputBoxStyle" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Background" Value="{StaticResource TileBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
      <Setter Property="FontSize" Value="{StaticResource BaseFontSize}"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="False"
                            HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource SubtleTextBrush}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The running step's progress bar. -->
    <Style x:Key="ProgressStyle" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="3" Background="{StaticResource LineBrush}"/>
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{StaticResource AccentBrush}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The right column of the repair page: a panel's title and its lines. -->
    <Style x:Key="PanelTitleStyle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="{StaticResource TitleFontSize}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="PanelTextStyle" TargetType="TextBlock">
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="18"/>
      <Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>
    </Style>
    <Style x:Key="PanelSmallTextStyle" TargetType="TextBlock" BasedOn="{StaticResource PanelTextStyle}">
      <Setter Property="FontSize" Value="{StaticResource SmallFontSize}"/>
      <Setter Property="LineHeight" Value="16"/>
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

          <!-- Left nav: one entry per page (repair plan, XAML contract additions). The model decides which is chosen. -->
          <DockPanel LastChildFill="False" Margin="8,6,8,14">
            <RadioButton x:Name="NavSetup" DockPanel.Dock="Top" Style="{StaticResource NavStyle}" Tag="a:Page:setup">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="NavSetupGlyph" Style="{StaticResource NavGlyphStyle}" Text="&#xE7F4;"/>
                <TextBlock Grid.Column="1" Tag="t:nav.setup" Margin="10,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </Grid>
            </RadioButton>
            <RadioButton x:Name="NavRepair" DockPanel.Dock="Top" Style="{StaticResource NavStyle}" Tag="a:Page:repair" Margin="0,4,0,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="NavRepairGlyph" Style="{StaticResource NavGlyphStyle}" Text="&#xE90F;"/>
                <TextBlock Grid.Column="1" Tag="t:nav.repair" Margin="10,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </Grid>
            </RadioButton>
            <TextBlock x:Name="VersionText" DockPanel.Dock="Bottom" Margin="14,0,0,0" HorizontalAlignment="Left" FlowDirection="LeftToRight"
                       FontSize="{StaticResource SmallFontSize}" Foreground="{StaticResource DimTextBrush}"/>
          </DockPanel>

          <!-- Center: banners, the machine card and the page: the setup options or the repair page. -->
          <StackPanel x:Name="CenterPanel" Grid.Column="1" Margin="4,6,14,12">
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
                    <!-- The setup page shows the name the PC will get; the repair page the name it has. -->
                    <StackPanel x:Name="MachineNewNamePart" Orientation="Horizontal">
                      <Ellipse Width="3" Height="3" Margin="10,0" VerticalAlignment="Center" Fill="{StaticResource DimTextBrush}"/>
                      <TextBlock Tag="t:machine.newName" Foreground="{StaticResource SubtleTextBrush}"/>
                      <TextBlock x:Name="MachineNewName" FlowDirection="LeftToRight" Margin="6,0,0,0" FontWeight="SemiBold"/>
                    </StackPanel>
                    <StackPanel x:Name="MachinePcNamePart" Orientation="Horizontal" Visibility="Collapsed">
                      <Ellipse Width="3" Height="3" Margin="10,0" VerticalAlignment="Center" Fill="{StaticResource DimTextBrush}"/>
                      <TextBlock Tag="t:machine.pcName" Foreground="{StaticResource SubtleTextBrush}"/>
                      <TextBlock x:Name="MachinePcName" FlowDirection="LeftToRight" Margin="6,0,0,0" FontWeight="SemiBold"/>
                    </StackPanel>
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

            <Grid x:Name="SetupOptions" Margin="0,12,0,0">
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

              <TextBlock Grid.Row="4" Style="{StaticResource RowLabelStyle}" Tag="t:row.updates"/>
              <WrapPanel Grid.Row="4" Grid.Column="1">
                <RadioButton x:Name="UpdatesFull" Style="{StaticResource TileStyle}" Tag="a:WindowsUpdate:FULL">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE895;"/><TextBlock Tag="t:updates.full" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
                <RadioButton x:Name="UpdatesDrivers" Style="{StaticResource TileStyle}" Tag="a:WindowsUpdate:DRIVERS">
                  <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TileGlyphStyle}" Text="&#xE950;"/><TextBlock Tag="t:updates.drivers" VerticalAlignment="Center"/></StackPanel>
                </RadioButton>
              </WrapPanel>

              <TextBlock Grid.Row="5" Style="{StaticResource RowLabelStyle}" Tag="t:row.apps"/>
              <WrapPanel Grid.Row="5" Grid.Column="1">
                <Border Style="{StaticResource ChipStyle}" Margin="0,0,18,6">
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Style="{StaticResource TileGlyphStyle}" Foreground="{StaticResource AccentBrush}" Text="&#xE73E;"/>
                    <TextBlock Tag="t:apps.chrome" VerticalAlignment="Center"/>
                  </StackPanel>
                </Border>
                <CheckBox x:Name="SevenZipSwitch" Style="{StaticResource SwitchStyle}" Tag="a:SevenZip:" Height="30" Margin="0,0,0,6">
                  <TextBlock Tag="t:apps.sevenZip" FlowDirection="LeftToRight"/>
                </CheckBox>
                <CheckBox x:Name="ZoomSwitch" Style="{StaticResource SwitchStyle}" Tag="a:Zoom:" Height="30" Margin="18,0,0,6">
                  <TextBlock Tag="t:apps.zoom" FlowDirection="LeftToRight"/>
                </CheckBox>
              </WrapPanel>

              <TextBlock Grid.Row="6" Style="{StaticResource RowLabelStyle}" Tag="t:row.tweaks" Margin="0,11,10,0"/>
              <StackPanel x:Name="TweakPanel" Grid.Row="6" Grid.Column="1" Margin="0"/>

              <TextBlock Grid.Row="7" Style="{StaticResource RowLabelStyle}" Tag="t:row.restore" Margin="0,11,10,0"/>
              <Border Grid.Row="7" Grid.Column="1" Style="{StaticResource TweakRowStyle}" Margin="0">
                <CheckBox x:Name="RestoreSwitch" Style="{StaticResource SwitchStyle}" Tag="a:RestorePoint:">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource TweakGlyphStyle}" Text="&#xE777;"/>
                    <TextBlock Tag="t:restore.label" VerticalAlignment="Center"/>
                  </StackPanel>
                </CheckBox>
              </Border>
            </Grid>

            <!-- Repair & diagnostics (repair spec 4.1): the safety strip, the action tiles row by row, the complaint. The
                 view colours the chips and sets every tile's state and tooltip from the model's gates. -->
            <Grid x:Name="RepairCenter" Visibility="Collapsed" Margin="0,10,0,0">
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
              </Grid.RowDefinitions>

              <TextBlock Grid.Row="0" Style="{StaticResource RowLabelStyle}" Tag="t:repair.row.safety"/>
              <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,4">
                <WrapPanel x:Name="StripPanel">
                  <Border x:Name="ChipRestart" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipRestartGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipRestartText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Button x:Name="ChipRestartButton" Style="{StaticResource SmallButtonStyle}" Tag="a:Restart:" Visibility="Collapsed">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource ChipGlyphStyle}" Text="&#xE777;"/>
                      <TextBlock Tag="t:repair.restartChip" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Button>
                  <Border x:Name="ChipFree" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipFreeGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipFreeText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="ChipBitLocker" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipBitLockerGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipBitLockerText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="ChipInternet" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipInternetGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipInternetText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="ChipDisk" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipDiskGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipDiskText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="ChipPower" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipPowerGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipPowerText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="ChipStick" Style="{StaticResource StripChipStyle}">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock x:Name="ChipStickGlyph" Style="{StaticResource ChipGlyphStyle}"/>
                      <TextBlock x:Name="ChipStickText" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                </WrapPanel>
                <!-- Shown with a failing disk: the shop rule, image first (spec 5). The row follows its switch. -->
                <Border Style="{StaticResource TweakRowStyle}" Height="34" Margin="0,0,6,6" Visibility="{Binding Visibility, ElementName=BackedUpSwitch}">
                  <CheckBox x:Name="BackedUpSwitch" Style="{StaticResource SwitchStyle}" Tag="a:BackedUp:" Visibility="Collapsed">
                    <TextBlock Tag="t:repair.backedUp" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                  </CheckBox>
                </Border>
                <Border x:Name="NoStickBanner" Visibility="Collapsed" Background="{StaticResource DangerBackBrush}" BorderBrush="{StaticResource DangerLineBrush}"
                        BorderThickness="1" CornerRadius="6" Padding="10,6" Margin="0,0,6,6">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Style="{StaticResource ChipGlyphStyle}" VerticalAlignment="Top" Margin="0,1,8,0" Text="&#xE88E;"/>
                    <TextBlock Grid.Column="1" Tag="t:repair.noStick" TextWrapping="Wrap"/>
                  </Grid>
                </Border>
              </StackPanel>

              <TextBlock Grid.Row="1" Style="{StaticResource RowLabelStyle}" Tag="t:repair.row.check" Margin="0,10,10,0"/>
              <UniformGrid Grid.Row="1" Grid.Column="1" Columns="2" Margin="0,0,0,4">
                <Button x:Name="TileHealth" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:health">
                  <DockPanel>
                    <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE9D9;"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.health.title"/>
                      <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.health.line"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
                <Button x:Name="TileQuickReport" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:quickReport">
                  <DockPanel>
                    <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE9F9;"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.quickReport.title"/>
                      <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.quickReport.line"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
              </UniformGrid>

              <TextBlock Grid.Row="2" Style="{StaticResource RowLabelStyle}" Tag="t:repair.row.repair" Margin="0,10,10,0"/>
              <UniformGrid Grid.Row="2" Grid.Column="1" Columns="2" Margin="0,0,0,4">
                <Button x:Name="TileStandard" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:standard">
                  <DockPanel>
                    <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE90F;"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.standard.title"/>
                      <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.standard.line"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
                <Button x:Name="TilePostClone" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:postClone">
                  <DockPanel>
                    <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE8C8;"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.postClone.title"/>
                      <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.postClone.line"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
              </UniformGrid>

              <TextBlock Grid.Row="3" Style="{StaticResource RowLabelStyle}" Tag="t:repair.row.advanced" Margin="0,10,10,0"/>
              <StackPanel Grid.Row="3" Grid.Column="1" Margin="0,0,0,4">
                <UniformGrid Columns="2">
                  <Button x:Name="TileWuReset" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:wuReset">
                    <DockPanel>
                      <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE895;"/>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.wuReset.title"/>
                        <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.wuReset.line"/>
                      </StackPanel>
                    </DockPanel>
                  </Button>
                  <Button x:Name="TileNetReset" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:netReset">
                    <DockPanel>
                      <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE968;"/>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.netReset.title"/>
                        <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.netReset.line"/>
                      </StackPanel>
                    </DockPanel>
                  </Button>
                  <Button x:Name="TileDiskCheck" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:diskCheck">
                    <DockPanel>
                      <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xEDA2;"/>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.diskCheck.title"/>
                        <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.diskCheck.line"/>
                      </StackPanel>
                    </DockPanel>
                  </Button>
                  <Button x:Name="TileGhosts" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:ghosts">
                    <DockPanel>
                      <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE772;"/>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.ghosts.title"/>
                        <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.ghosts.line"/>
                      </StackPanel>
                    </DockPanel>
                  </Button>
                </UniformGrid>
                <Button x:Name="NetRestoreButton" Style="{StaticResource SmallButtonStyle}" Tag="a:Tile:netRestore" HorizontalAlignment="Left" Visibility="Collapsed"
                        ToolTipService.ShowOnDisabled="True">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource ChipGlyphStyle}" Text="&#xE7A7;"/>
                    <TextBlock Tag="t:tile.netRestore.title" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
              </StackPanel>

              <TextBlock Grid.Row="4" Style="{StaticResource RowLabelStyle}" Tag="t:repair.row.report" Margin="0,10,10,0"/>
              <UniformGrid Grid.Row="4" Grid.Column="1" Columns="2" Margin="0,0,0,4">
                <Button x:Name="TileFullReport" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:fullReport">
                  <DockPanel>
                    <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE8A5;"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.fullReport.title"/>
                      <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.fullReport.line"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
                <Button x:Name="TileCompare" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:compare">
                  <DockPanel>
                    <TextBlock Style="{StaticResource RepairTileGlyphStyle}" Text="&#xE8F1;"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Style="{StaticResource TileTitleStyle}" Tag="t:tile.compare.title"/>
                      <TextBlock Style="{StaticResource TileLineStyle}" Tag="t:tile.compare.line"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
              </UniformGrid>

              <!-- The customer complaint (spec 4.1): typed before a report, it goes at the top of it. The hint shows
                   while the box is empty. -->
              <TextBlock Grid.Row="5" Style="{StaticResource RowLabelStyle}" Tag="t:repair.complaint" TextWrapping="Wrap" TextTrimming="None" Margin="0,8,2,0"/>
              <Grid Grid.Row="5" Grid.Column="1" Margin="0,0,6,0">
                <TextBox x:Name="ComplaintBox" Style="{StaticResource InputBoxStyle}" Tag="a:Complaint:" MaxLength="2000" AcceptsReturn="True"
                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Height="52"/>
                <TextBlock Tag="t:repair.complaintHint" Margin="9,6,9,0" IsHitTestVisible="False" Foreground="{StaticResource DimTextBrush}" TextTrimming="CharacterEllipsis">
                  <TextBlock.Style>
                    <Style TargetType="TextBlock">
                      <Setter Property="Visibility" Value="Collapsed"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Text, ElementName=ComplaintBox}" Value="">
                          <Setter Property="Visibility" Value="Visible"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </TextBlock.Style>
                </TextBlock>
              </Grid>
            </Grid>
          </StackPanel>

          <!-- Right: the setup page's card (what will happen, Cancel and Start) or the repair page's. As high as the
               visible area, so the buttons stay at the card's bottom; on a short (clamped) window the list scrolls
               inside the card, so every line stays reachable. -->
          <Border Grid.Column="2" VerticalAlignment="Top" Padding="0,6,12,12" Height="{Binding ViewportHeight, ElementName=ContentScroll}">
            <Grid>
            <Border x:Name="SetupRight" Style="{StaticResource CardStyle}">
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
                <ScrollViewer x:Name="PlanScroll" Style="{StaticResource OverlayScrollStyle}" HorizontalScrollBarVisibility="Disabled"
                              VerticalScrollBarVisibility="Auto" Focusable="False">
                  <StackPanel x:Name="PlanList" Margin="16,0,16,0"/>
                </ScrollViewer>
              </DockPanel>
            </Border>

            <!-- The repair page's card: one panel at a time, in this priority: the confirmation, the run, the result,
                 what the tile does (spec 4.1, 4.2). The rows of the lists are the view's. -->
            <Border x:Name="RepairRight" Style="{StaticResource CardStyle}" Visibility="Collapsed">
              <Grid>
                <DockPanel x:Name="WhatPanel">
                  <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionTitleStyle}" Tag="t:what.title" Margin="16,14,16,10"/>
                  <ScrollViewer Style="{StaticResource OverlayScrollStyle}" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" Focusable="False">
                    <StackPanel Margin="16,0,16,16">
                      <Grid x:Name="WhatHeader" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="WhatGlyph" Style="{StaticResource RepairTileGlyphStyle}" VerticalAlignment="Top"/>
                        <TextBlock x:Name="WhatTitle" Grid.Column="1" Style="{StaticResource PanelTitleStyle}" VerticalAlignment="Center"/>
                      </Grid>
                      <TextBlock x:Name="WhatText" Style="{StaticResource PanelTextStyle}"/>
                      <StackPanel x:Name="WhatChanges" Margin="0,12,0,0"/>
                    </StackPanel>
                  </ScrollViewer>
                </DockPanel>

                <DockPanel x:Name="ConfirmPanel" Visibility="Collapsed">
                  <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionTitleStyle}" Tag="t:confirm.title" Margin="16,14,16,6"/>
                  <TextBlock x:Name="ConfirmTitle" DockPanel.Dock="Top" Style="{StaticResource PanelTitleStyle}" Margin="16,0,16,10"/>
                  <Grid DockPanel.Dock="Bottom" Margin="16,10,16,16">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="ConfirmCancelButton" Style="{StaticResource PlainButtonStyle}" Tag="a:ConfirmCancel:" MinWidth="88" Margin="0,0,8,0">
                      <TextBlock Tag="t:confirm.cancel"/>
                    </Button>
                    <Button x:Name="ConfirmButton" Grid.Column="1" Style="{StaticResource AccentButtonStyle}" Tag="a:Confirm:" Focusable="False">
                      <TextBlock x:Name="ConfirmGoText" FontWeight="Bold"/>
                    </Button>
                  </Grid>
                  <StackPanel x:Name="YesPanel" DockPanel.Dock="Bottom" Margin="16,10,16,0" Visibility="Collapsed">
                    <TextBlock Tag="t:confirm.yesPrompt" FontWeight="SemiBold" Margin="0,0,0,6"/>
                    <TextBox x:Name="YesBox" Style="{StaticResource InputBoxStyle}" Tag="a:YesText:" MaxLength="8" Height="34" FontWeight="SemiBold"
                             VerticalContentAlignment="Center"/>
                  </StackPanel>
                  <CheckBox x:Name="AtPcSwitch" DockPanel.Dock="Bottom" Style="{StaticResource SwitchStyle}" Tag="a:AtPc:" Margin="16,10,16,0" Visibility="Collapsed">
                    <TextBlock Tag="t:confirm.atPc" TextWrapping="Wrap"/>
                  </CheckBox>
                  <ScrollViewer x:Name="ConfirmScroll" Style="{StaticResource OverlayScrollStyle}" HorizontalScrollBarVisibility="Disabled"
                                VerticalScrollBarVisibility="Auto" Focusable="False">
                    <StackPanel Margin="16,0,16,0">
                      <StackPanel x:Name="ConfirmLines"/>
                      <StackPanel x:Name="ConfirmItems"/>
                    </StackPanel>
                  </ScrollViewer>
                </DockPanel>

                <DockPanel x:Name="RunPanel" Visibility="Collapsed">
                  <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionTitleStyle}" Tag="t:run.title" Margin="16,14,16,6"/>
                  <TextBlock x:Name="RunTitle" DockPanel.Dock="Top" Style="{StaticResource PanelTitleStyle}" Margin="16,0,16,10"/>
                  <StackPanel DockPanel.Dock="Bottom" Margin="16,8,16,16">
                    <TextBlock x:Name="CloseRefusedText" Tag="t:run.closeRefused" Style="{StaticResource PanelSmallTextStyle}" Foreground="{StaticResource WarnBrush}"
                               Margin="0,0,0,8" Visibility="Collapsed"/>
                    <TextBlock x:Name="StoppingText" Style="{StaticResource PanelSmallTextStyle}" Foreground="{StaticResource WarnBrush}" Margin="0,0,0,8" Visibility="Collapsed"/>
                    <Button x:Name="StopButton" Style="{StaticResource PlainButtonStyle}" Tag="a:Stop:">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Style="{StaticResource GlyphStyle}" FontSize="{StaticResource SmallGlyphFontSize}" Margin="0,0,8,0" Text="&#xE71A;"/>
                        <TextBlock Tag="t:run.stop" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Button>
                  </StackPanel>
                  <Border DockPanel.Dock="Bottom" Margin="16,8,16,0" Background="{StaticResource BgBrush}" CornerRadius="4" Padding="8,6">
                    <TextBlock x:Name="RunLog" FlowDirection="LeftToRight" FontFamily="{StaticResource MonoFont}" FontSize="{StaticResource LogFontSize}"
                               Foreground="{StaticResource SubtleTextBrush}" TextTrimming="CharacterEllipsis" LineHeight="15" LineStackingStrategy="BlockLineHeight"/>
                  </Border>
                  <TextBlock x:Name="RunElapsed" DockPanel.Dock="Bottom" Margin="16,8,16,0" FontSize="{StaticResource SmallFontSize}" Foreground="{StaticResource SubtleTextBrush}"/>
                  <ScrollViewer Style="{StaticResource OverlayScrollStyle}" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" Focusable="False">
                    <!-- The step rows are the view's; the bar row follows the running step when its percent is known. -->
                    <StackPanel x:Name="RunSteps" Margin="16,0,16,0">
                      <Grid x:Name="RunBarRow" Margin="22,0,0,6">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <ProgressBar x:Name="RunBar" Style="{StaticResource ProgressStyle}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="RunPercent" Grid.Column="1" Margin="8,0,0,0" FlowDirection="LeftToRight" FontSize="{StaticResource SmallFontSize}"
                                   Foreground="{StaticResource SubtleTextBrush}"/>
                      </Grid>
                    </StackPanel>
                  </ScrollViewer>
                </DockPanel>

                <DockPanel x:Name="ResultPanel" Visibility="Collapsed">
                  <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionTitleStyle}" Tag="t:result.title" Margin="16,14,16,8"/>
                  <Border x:Name="ResultBanner" DockPanel.Dock="Top" Margin="16,0,16,10" CornerRadius="6" Padding="10,8">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock x:Name="ResultGlyph" Style="{StaticResource GlyphStyle}" FontSize="{StaticResource MachineGlyphFontSize}" Margin="0,0,10,0"/>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock x:Name="ResultAction" FontWeight="SemiBold" TextWrapping="Wrap"/>
                        <TextBlock x:Name="ResultOutcome" FontSize="{StaticResource SmallFontSize}" Foreground="{StaticResource SubtleTextBrush}"/>
                      </StackPanel>
                    </Grid>
                  </Border>
                  <Grid DockPanel.Dock="Bottom" Margin="16,10,16,16">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="OpenFolderButton" Style="{StaticResource PlainButtonStyle}" Tag="a:OpenFolder:" Padding="6,0" Margin="0,0,4,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Style="{StaticResource GlyphStyle}" FontSize="{StaticResource SmallGlyphFontSize}" Margin="0,0,6,0" Text="&#xE838;"/>
                        <TextBlock Tag="t:result.openFolder" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="RestartButton" Grid.Column="1" Style="{StaticResource PlainButtonStyle}" Tag="a:Restart:" Padding="6,0" Margin="4,0,0,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Style="{StaticResource GlyphStyle}" FontSize="{StaticResource SmallGlyphFontSize}" Margin="0,0,6,0" Text="&#xE777;"/>
                        <TextBlock Tag="t:result.restart" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Button>
                  </Grid>
                  <ScrollViewer Style="{StaticResource OverlayScrollStyle}" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" Focusable="False">
                    <StackPanel Margin="16,0,16,0">
                      <StackPanel x:Name="ResultFindings"/>
                      <TextBlock x:Name="ResultRestartNeeded" Tag="t:result.restartNeeded" Style="{StaticResource PanelTextStyle}" Foreground="{StaticResource WarnBrush}"
                                 FontWeight="SemiBold" Margin="0,4,0,0"/>
                      <Button x:Name="OfferDiskCheckButton" Style="{StaticResource RepairTileStyle}" Tag="a:Tile:diskCheck" Height="Auto" Padding="10,8" Margin="0,10,0,0">
                        <DockPanel>
                          <TextBlock Style="{StaticResource ChipGlyphStyle}" Foreground="{StaticResource AccentBrush}" Text="&#xEDA2;"/>
                          <TextBlock Tag="t:tile.diskCheck.title" FontWeight="SemiBold" TextWrapping="Wrap" VerticalAlignment="Center"/>
                        </DockPanel>
                      </Button>
                      <Button x:Name="OfferDismButton" Style="{StaticResource RepairTileStyle}" Tag="a:Offer:dismSource" Height="Auto" Padding="10,8" Margin="0,8,0,0">
                        <DockPanel>
                          <TextBlock Style="{StaticResource ChipGlyphStyle}" Foreground="{StaticResource AccentBrush}" VerticalAlignment="Top" Margin="0,1,7,0" Text="&#xE90F;"/>
                          <StackPanel>
                            <TextBlock Tag="t:tile.dismSource.title" FontWeight="SemiBold" TextWrapping="Wrap"/>
                            <TextBlock x:Name="OfferDismText" FlowDirection="LeftToRight" HorizontalAlignment="Left" Style="{StaticResource PanelSmallTextStyle}"
                                       Foreground="{StaticResource SubtleTextBrush}" Margin="0,2,0,0"/>
                            <TextBlock x:Name="OfferDismNote" Style="{StaticResource PanelSmallTextStyle}" Foreground="{StaticResource WarnBrush}" Margin="0,4,0,0"/>
                          </StackPanel>
                        </DockPanel>
                      </Button>
                      <TextBlock x:Name="ResultFilesLabel" Tag="t:result.files" Style="{StaticResource SectionTitleStyle}" Margin="0,14,0,4"/>
                      <TextBlock x:Name="ResultFiles" FlowDirection="LeftToRight" HorizontalAlignment="Left" Style="{StaticResource PanelSmallTextStyle}"
                                 Foreground="{StaticResource SubtleTextBrush}" Margin="0,0,0,10"/>
                    </StackPanel>
                  </ScrollViewer>
                </DockPanel>
              </Grid>
            </Border>
            </Grid>
          </Border>
        </Grid>
      </ScrollViewer>
    </Grid>
  </Border>
</Window>
'@
