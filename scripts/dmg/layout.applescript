-- Lays out the mounted disk image's Finder window: icon view, no toolbar, sidebar or status bar,
-- 128-point icons on the background picture, the app on the left and Applications on the right.
--   osascript layout.applescript <volume name> <app item name> <width> <window height, title bar included> <app x> <apps x> <icons y>
on run argv
	set volumeName to item 1 of argv
	set appName to item 2 of argv
	set contentWidth to (item 3 of argv) as integer
	set contentHeight to (item 4 of argv) as integer
	set appX to (item 5 of argv) as integer
	set applicationsX to (item 6 of argv) as integer
	set iconsY to (item 7 of argv) as integer
	tell application "Finder"
		tell disk volumeName
			open
			set theWindow to container window
			set current view of theWindow to icon view
			set toolbar visible of theWindow to false
			set statusbar visible of theWindow to false
			try
				set sidebar width of theWindow to 0
			end try
			set windowX to 200
			set windowY to 140
			set bounds of theWindow to {windowX, windowY, windowX + contentWidth, windowY + contentHeight}
			set viewOptions to icon view options of theWindow
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 13
			set label position of viewOptions to bottom
			set shows item info of viewOptions to false
			set shows icon preview of viewOptions to true
			set background picture of viewOptions to file ".background:background.tiff"
			set position of item appName of theWindow to {appX, iconsY}
			set position of item "Applications" of theWindow to {applicationsX, iconsY}
			close
			open
			update without registering applications
			delay 1
			-- The bounds again: a reopened window can come back at its old size.
			set bounds of container window to {windowX, windowY, windowX + contentWidth, windowY + contentHeight}
			delay 1
			close
		end tell
	end tell
end run
