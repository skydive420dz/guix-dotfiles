;;; sk-theme-generated.el --- SYNTHETIC FIXTURE - DO NOT INSTALL -*- lexical-binding: t; -*-
;;; schema=1 palette=synthetic fixture only

(setq modus-themes-variable-pitch-ui t
      modus-vivendi-tinted-palette-overrides
      '(
    (bg-main "#101010")
    (bg-dim "#181818")
    (bg-active "#303030")
    (fg-main "#ffffff")
    (fg-alt "#d0d0d0")
    (fg-dim "#a0a0a0")
    (border "#767676")
    (bg-region "#005f87")
    (fg-region "#ffffff")
    (cursor "#ff5fff")
    (err "#ff6b6b")
    (warning "#ffd700")
    (info "#00d7ff")
    (bg-term-black "#000000")
    (fg-term-black "#000000")
    (bg-term-red "#ff5f5f")
    (fg-term-red "#ff5f5f")
    (bg-term-green "#00ff87")
    (fg-term-green "#00ff87")
    (bg-term-yellow "#ffd700")
    (fg-term-yellow "#ffd700")
    (bg-term-blue "#5fafff")
    (fg-term-blue "#5fafff")
    (bg-term-magenta "#ff5fff")
    (fg-term-magenta "#ff5fff")
    (bg-term-cyan "#00d7ff")
    (fg-term-cyan "#00d7ff")
    (bg-term-white "#d0d0d0")
    (fg-term-white "#d0d0d0")
    (bg-term-black-bright "#767676")
    (fg-term-black-bright "#767676")
    (bg-term-red-bright "#ff8787")
    (fg-term-red-bright "#ff8787")
    (bg-term-green-bright "#5fffaf")
    (fg-term-green-bright "#5fffaf")
    (bg-term-yellow-bright "#ffff5f")
    (fg-term-yellow-bright "#ffff5f")
    (bg-term-blue-bright "#87d7ff")
    (fg-term-blue-bright "#87d7ff")
    (bg-term-magenta-bright "#ff87ff")
    (fg-term-magenta-bright "#ff87ff")
    (bg-term-cyan-bright "#5fffff")
    (fg-term-cyan-bright "#5fffff")
    (bg-term-white-bright "#ffffff")
    (fg-term-white-bright "#ffffff")
        ))

(mapc #'disable-theme custom-enabled-themes)
(load-theme 'modus-vivendi-tinted t)
(set-face-attribute 'default nil :family "Fixture Mono" :height 130)
(set-face-attribute 'fixed-pitch nil :family "Fixture Mono" :height 130)
(set-face-attribute 'variable-pitch nil :family "Fixture UI" :height 130)

(when (display-graphic-p)
  (dolist (family
           '(
             "Fixture Symbols"
             "Fixture Emoji"
             ))
    (when (find-font (font-spec :name family))
      (set-fontset-font t 'symbol family nil 'append))))

(provide 'sk-theme-generated)
;;; sk-theme-generated.el ends here
