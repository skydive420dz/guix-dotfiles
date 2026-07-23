'((schema-version . 2)
  (kind . fixture)
  (provenance
   (palette-authority . frozen-modus-subset)
   (theme . modus-vivendi-tinted)
   (palette-source . "synthetic fixture only")
   (modus-version . "fixture-0")
   (theme-source-sha256 . "0000000000000000000000000000000000000000000000000000000000000000")
   (core-source-sha256 . "0000000000000000000000000000000000000000000000000000000000000000")
   (guix-revision . "0000000000000000000000000000000000000000")
   (emacs-version . "fixture-0")
   (mapping-version . 1))
  (roles
   (canvas . "#101010")
   (surface . "#181818")
   (surface-raised . "#303030")
   (text . "#ffffff")
   (text-muted . "#d0d0d0")
   (text-disabled . "#a0a0a0")
   (accent . "#00d7ff")
   (on-accent . "#000000")
   (selection . "#005f87")
   (on-selection . "#ffffff")
   (focus . "#ffff00")
   (success . "#00ff87")
   (warning . "#ffd700")
   (error . "#ff6b6b")
   (border . "#767676")
   (shadow . "#000000")
   (cursor . "#ff5fff")
   (on-cursor . "#000000"))
  (ansi
   (black . "#000000")
   (red . "#ff5f5f")
   (green . "#00ff87")
   (yellow . "#ffd700")
   (blue . "#5fafff")
   (magenta . "#ff5fff")
   (cyan . "#00d7ff")
   (white . "#d0d0d0")
   (bright-black . "#767676")
   (bright-red . "#ff8787")
   (bright-green . "#5fffaf")
   (bright-yellow . "#ffff5f")
   (bright-blue . "#87d7ff")
   (bright-magenta . "#ff87ff")
   (bright-cyan . "#5fffff")
   (bright-white . "#ffffff"))
  (typography
   (fixed-family . "Fixture Mono")
   (ui-family . "Fixture UI")
   (ui-size-pt . 13)
   (fallback-families
    "Fixture Symbols"
    "Fixture Emoji"))
  (desktop
   (color-scheme . dark)
   (gtk3-theme . "Fixture-Dark")
   (gtk4-theme . "Fixture")
   (icon-theme . "Fixture-Icons")
   (cursor-theme . "Fixture-Cursor")
   (cursor-size-px . 24)
   (logical-dpi . 96)
   (integer-scale . 1)
   (scale-ownership . inherit-verified)
   (gtk4-test-application . "gtk4-widget-factory"))
  (calibrations
   (emacs-face-height-tenths-pt . 130)
   (kitty-font-size-pt . 15.0)
   (picom-emacs-opacity-percent . 90)
   (kitty-background-opacity-ratio . 0.5)
   (kitty-cursor-trail-role . focus))
  (assets
   (wallpaper
    (path . "assets/wallpaper.png")
    (fit . zoom)))
  (contrast
   (primary-text-min . 7)
   (secondary-text-min . 9/2)
   (ui-component-min . 3)
   (transparent-hand-test-required? . #t))
  (fish
   (prompt
    (path
     (foreground . text)
     (background . none)
     (attributes))
    (path-background
     (foreground . none)
     (background . surface-raised)
     (attributes))
    (git-branch
     (foreground . accent)
     (background . none)
     (attributes))
    (git-status
     (foreground . text-muted)
     (background . none)
     (attributes))
    (success
     (foreground . success)
     (background . none)
     (attributes))
    (error
     (foreground . error)
     (background . none)
     (attributes)))
   (syntax
    (normal
     (foreground . text)
     (background . none)
     (attributes))
    (command
     (foreground . success)
     (background . none)
     (attributes))
    (keyword
     (foreground . accent)
     (background . none)
     (attributes bold))
    (quote
     (foreground . warning)
     (background . none)
     (attributes))
    (redirection
     (foreground . accent)
     (background . none)
     (attributes bold))
    (end
     (foreground . success)
     (background . none)
     (attributes))
    (error
     (foreground . error)
     (background . none)
     (attributes))
    (param
     (foreground . text)
     (background . none)
     (attributes))
    (valid-path
     (foreground . text)
     (background . none)
     (attributes underline))
    (option
     (foreground . accent)
     (background . none)
     (attributes))
    (comment
     (foreground . text-muted)
     (background . none)
     (attributes italics))
    (selection
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (operator
     (foreground . accent)
     (background . none)
     (attributes))
    (escape
     (foreground . warning)
     (background . none)
     (attributes))
    (autosuggestion
     (foreground . text-disabled)
     (background . none)
     (attributes))
    (cancel
     (foreground . error)
     (background . none)
     (attributes reverse))
    (search-match
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (history-current
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (host
     (foreground . text-muted)
     (background . none)
     (attributes))
    (host-remote
     (foreground . warning)
     (background . none)
     (attributes))
    (status
     (foreground . error)
     (background . none)
     (attributes))
    (cwd
     (foreground . success)
     (background . none)
     (attributes))
    (cwd-root
     (foreground . error)
     (background . none)
     (attributes))
    (user
     (foreground . success)
     (background . none)
     (attributes))
    (background
     (foreground . none)
     (background . canvas)
     (attributes))
    (statement-terminator
     (foreground . accent)
     (background . none)
     (attributes)))
   (pager
    (progress
     (foreground . on-accent)
     (background . accent)
     (attributes bold))
    (background
     (foreground . none)
     (background . surface)
     (attributes))
    (prefix
     (foreground . accent)
     (background . none)
     (attributes bold underline))
    (completion
     (foreground . text)
     (background . none)
     (attributes))
    (description
     (foreground . text-muted)
     (background . none)
     (attributes italics))
    (secondary-background
     (foreground . none)
     (background . surface-raised)
     (attributes))
    (secondary-prefix
     (foreground . accent)
     (background . none)
     (attributes bold))
    (secondary-completion
     (foreground . text)
     (background . none)
     (attributes))
    (secondary-description
     (foreground . text-muted)
     (background . none)
     (attributes italics))
    (selected-background
     (foreground . none)
     (background . selection)
     (attributes))
    (selected-prefix
     (foreground . on-selection)
     (background . selection)
     (attributes bold))
    (selected-completion
     (foreground . on-selection)
     (background . selection)
     (attributes))
    (selected-description
     (foreground . on-selection)
     (background . selection)
     (attributes italics))))
  (targets emacs kitty fish gtk3 gtk4 dunst x-session))
