# src/Toolbox/Strings.ps1
# The BenTech Toolbox's string table (toolbox spec 4.3): every fixed text of the window, in English and Hebrew,
# under the same keys. The window's TextBlocks name their key in Tag="t:<key>"; Set-ToolboxLanguage (Toolbox.ps1)
# fills them from New-ToolboxStringTable, which adds the keys that come from config.json: profile.<id>,
# tweak.<id>.title and tweak.<id>.desc. {0} and {1} are format arguments.
#
# This is the ONLY src file allowed to contain non-ASCII (UTF-8 with BOM, as every .ps1; tests\Encoding.Tests.ps1
# checks every other src file is ASCII). Nothing here reaches setup.log, the console or the report: those stay
# English and ASCII, and Choices hold ASCII ids only. No Hebrew string contains an apostrophe (these are
# single-quoted strings).
$script:ToolboxStrings = @{
  en = @{
    'app.title'             = 'BENTECH TOOLBOX'
    'nav.setup'             = 'New PC setup'
    'machine.serial'        = 'SN'
    'machine.newName'       = 'New name'
    'power.ac'              = 'On charger'
    'power.battery'         = 'On battery'
    'warn.notFresh'         = 'This PC already has user files or is older than {0} days'
    'warn.previous'         = 'Previous run: {0} - {1}'
    'warn.battery'          = 'On battery: BIOS updates will be skipped'
    'warn.screenConnect'    = 'ScreenConnect = unattended access: get the customer''s OK first'
    'warn.adminProtection'  = 'Setup is running as a different user than the one signed in (Windows Administrator protection, or an admin password typed for another account). It would not resume after a restart: sign in as this PC''s administrator, or turn Administrator protection off in Windows Security.'
    'row.profile'           = 'PROFILE'
    'row.type'              = 'TYPE'
    'row.office'            = 'OFFICE'
    'row.remote'            = 'REMOTE'
    'row.apps'              = 'APPS'
    'row.tweaks'            = 'TWEAKS'
    'row.restore'           = 'RESTORE'
    'type.laptop'           = 'Laptop'
    'type.desktop'          = 'Desktop'
    'office.craft'          = 'Craft (free)'
    'office.business'       = '365 Business'
    'office.home'           = '365 Home'
    'office.off'            = 'None'
    'remote.anydesk'        = 'AnyDesk'
    'remote.screenconnect'  = 'ScreenConnect'
    'remote.both'           = 'Both'
    'apps.chrome'           = 'Chrome (always)'
    'apps.sevenZip'         = '7-Zip'
    'restore.label'         = 'Restore point at the end'
    'plan.title'            = 'WHAT WILL HAPPEN'
    'button.start'          = 'START'
    'button.cancel'         = 'Cancel'
  }
  he = @{
    'app.title'             = 'ארגז הכלים של BENTECH'
    'nav.setup'             = 'הכנת מחשב חדש'
    'machine.serial'        = 'מספר סידורי'
    'machine.newName'       = 'שם חדש'
    'power.ac'              = 'מחובר לחשמל'
    'power.battery'         = 'על סוללה'
    'warn.notFresh'         = 'במחשב כבר יש קבצי משתמש, או שהוא הותקן לפני יותר מ-{0} ימים'
    'warn.previous'         = 'הרצה קודמת: {0} - {1}'
    'warn.battery'          = 'על סוללה: עדכוני BIOS ידולגו'
    'warn.screenConnect'    = 'ScreenConnect = גישה בלי אישור בכל חיבור: קודם לקבל את הסכמת הלקוח'
    'warn.adminProtection'  = 'ההתקנה רצה כמשתמש אחר מזה שמחובר (הגנת מנהל המערכת של Windows, או סיסמת מנהל שהוקלדה לחשבון אחר). היא לא תמשיך אחרי הפעלה מחדש: יש להתחבר כמנהל המחשב, או לכבות את Administrator protection באבטחת Windows.'
    'row.profile'           = 'פרופיל'
    'row.type'              = 'סוג'
    'row.office'            = 'אופיס'
    'row.remote'            = 'גישה מרחוק'
    'row.apps'              = 'תוכנות'
    'row.tweaks'            = 'שיפורים'
    'row.restore'           = 'שחזור'
    'type.laptop'           = 'נייד'
    'type.desktop'          = 'נייח'
    'office.craft'          = 'Craft (חינם)'
    'office.business'       = '365 עסקי'
    'office.home'           = '365 ביתי'
    'office.off'            = 'ללא'
    'remote.anydesk'        = 'AnyDesk'
    'remote.screenconnect'  = 'ScreenConnect'
    'remote.both'           = 'שניהם'
    'apps.chrome'           = 'Chrome (תמיד)'
    'apps.sevenZip'         = '7-Zip'
    'restore.label'         = 'נקודת שחזור בסוף ההתקנה'
    'plan.title'            = 'מה יקרה'
    'button.start'          = 'התחל'
    'button.cancel'         = 'ביטול'
  }
}
