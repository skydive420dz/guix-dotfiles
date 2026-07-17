;;; sk-theme-generated.el --- Generated theme adapter -*- lexical-binding: t; -*-
;;; schema=2 palette=GNU Emacs 30.2 etc/themes/modus-vivendi-tinted-theme.el

(setq modus-themes-variable-pitch-ui t
      modus-vivendi-tinted-palette-overrides
      '(
    (bg-main "#0d0e1c")
    (bg-dim "#1d2235")
    (bg-active "#4a4f69")
    (fg-main "#ffffff")
    (fg-alt "#c6daff")
    (fg-dim "#989898")
    (border "#61647a")
    (bg-region "#555a66")
    (fg-region "#ffffff")
    (cursor "#ff66ff")
    (err "#ff5f59")
    (warning "#fec43f")
    (info "#6ae4b9")
    (bg-term-black "#000000")
    (fg-term-black "#000000")
    (bg-term-red "#ff5f59")
    (fg-term-red "#ff5f59")
    (bg-term-green "#44bc44")
    (fg-term-green "#44bc44")
    (bg-term-yellow "#d0bc00")
    (fg-term-yellow "#d0bc00")
    (bg-term-blue "#2fafff")
    (fg-term-blue "#2fafff")
    (bg-term-magenta "#feacd0")
    (fg-term-magenta "#feacd0")
    (bg-term-cyan "#00d3d0")
    (fg-term-cyan "#00d3d0")
    (bg-term-white "#a6a6a6")
    (fg-term-white "#a6a6a6")
    (bg-term-black-bright "#595959")
    (fg-term-black-bright "#595959")
    (bg-term-red-bright "#ff6b55")
    (fg-term-red-bright "#ff6b55")
    (bg-term-green-bright "#00c06f")
    (fg-term-green-bright "#00c06f")
    (bg-term-yellow-bright "#fec43f")
    (fg-term-yellow-bright "#fec43f")
    (bg-term-blue-bright "#79a8ff")
    (fg-term-blue-bright "#79a8ff")
    (bg-term-magenta-bright "#b6a0ff")
    (fg-term-magenta-bright "#b6a0ff")
    (bg-term-cyan-bright "#6ae4b9")
    (fg-term-cyan-bright "#6ae4b9")
    (bg-term-white-bright "#ffffff")
    (fg-term-white-bright "#ffffff")
        ))

(mapc #'disable-theme custom-enabled-themes)
(load-theme 'modus-vivendi-tinted t)
(set-face-attribute 'default nil :family "JetBrainsMono Nerd Font Mono" :height 120)
(set-face-attribute 'fixed-pitch nil :family "JetBrainsMono Nerd Font Mono" :height 120)
(set-face-attribute 'variable-pitch nil :family "JetBrainsMono Nerd Font" :height 110)

(when (display-graphic-p)
  (dolist (family
           '(
             "Symbols Nerd Font Mono"
             "Noto Color Emoji"
             "Font Awesome"
             "Material Icons"
             ))
    (when (find-font (font-spec :name family))
      (set-fontset-font t 'symbol family nil 'append))))

(provide 'sk-theme-generated)
;;; sk-theme-generated.el ends here
