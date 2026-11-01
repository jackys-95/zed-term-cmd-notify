property testDirectory : missing value

on configureDirectory()
	set testDirectory to do shell script "/usr/bin/printenv ZED_APPLESCRIPT_PROBE_DIRECTORY"
	if testDirectory does not start with "/" then
		error "Set ZED_APPLESCRIPT_PROBE_DIRECTORY to an existing absolute runtime directory."
	end if
end configureDirectory

on recordEvent(eventText)
	set logFile to open for access (POSIX file (testDirectory & "/events.log")) with write permission
	try
		write ((current date as text) & " | " & eventText & linefeed) to logFile starting at eof
		close access logFile
	on error errorText number errorNumber
		close access logFile
		error errorText number errorNumber
	end try
end recordEvent

on activateZed()
	my recordEvent("ACTIVATION_REQUESTED")
	try
		tell application id "dev.zed.Zed"
			activate
		end tell
		delay 0.5
		tell application id "dev.zed.Zed"
			set zedIsFrontmost to frontmost
		end tell
		my recordEvent("ZED_FRONTMOST=" & (zedIsFrontmost as text))
	on error errorText number errorNumber
		my recordEvent("ACTIVATION_ERROR " & errorNumber & ": " & errorText)
	end try
end activateZed

on run
	my configureDirectory()
	set previouslyPosted to false
	try
		do shell script "/usr/bin/test -f " & quoted form of (testDirectory & "/posted-identified")
		set previouslyPosted to true
	end try
	if previouslyPosted then
		my recordEvent("SUBSEQUENT_RUN")
		my activateZed()
	else
		do shell script "/usr/bin/touch " & quoted form of (testDirectory & "/posted-identified")
		my recordEvent("NOTIFICATION_POST_REQUESTED")
		display notification "Switch to another app, then click this notification to bring Zed forward." with title "Zed bridge click test"
		my recordEvent("NOTIFICATION_POST_RETURNED")
		delay 1
	end if
end run

on reopen
	my configureDirectory()
	my recordEvent("REOPEN")
	my activateZed()
end reopen
