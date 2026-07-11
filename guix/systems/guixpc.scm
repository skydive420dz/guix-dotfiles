;; This is an operating system configuration generated
;; by the graphical installer.
;;
;; Once installation is complete, you can learn and modify
;; this file to tweak the system configuration, and pass it
;; to the 'guix system reconfigure' command to effect your
;; changes.


;; Indicate which modules to import to access the variables
;; used in this configuration.
(use-modules (gnu)
             (guix gexp)
             (nonguix transformations))
(use-service-modules cups desktop networking ssh sound xorg)

((nonguix-transformation-guix)
 ((nonguix-transformation-linux)
  (operating-system
  (locale "en_US.utf8")
  (timezone "America/New_York")
  (keyboard-layout
   (keyboard-layout "us"
    #:options '("caps:escape")))

  (host-name "guixpc")

  (kernel-arguments
   (cons* "modprobe.blacklist=pcspkr"
          "video=HDMI-A-1:3440x1440@60"
          %default-kernel-arguments))
  
  ;; The list of user accounts ('root' is implicit).
  (users (cons* (user-account
                  (name "skydive420dz")
                  (comment "Rafael Oliveira")
                  (group "users")

                  (home-directory "/home/skydive420dz")
                  (shell (file-append (specification->package "fish")
                                      "/bin/fish"))
                  (supplementary-groups '("wheel" "netdev" "audio" "video")))
                %base-user-accounts))

  ;; Packages installed system-wide.  Users can also install packages
  ;; under their own account: use 'guix search KEYWORD' to search
  ;; for packages and 'guix install PACKAGE' to install a package.
  (packages (append (list (specification->package "curl")
              (specification->package "fastfetch-minimal")
              (specification->package "btop")
              (specification->package "emacs")
              (specification->package "emacs-exwm")
              (specification->package "emacs-desktop-environment")
              (specification->package "xset")
              (specification->package "fzf")
              (specification->package "git")
			  (specification->package "bluez")
			  (specification->package "blueman")
			  (specification->package "bzmenu")
			  (specification->package "pipemixer")
			  (specification->package "pamixer")
			  (specification->package "fish")
			  (specification->package "ranger")
			  (specification->package "kitty")
			  (specification->package "ungoogled-chromium")
			  (specification->package "xdg-utils")
			  (specification->package "file")
			  (specification->package "bat")
			  (specification->package "chafa")
			  (specification->package "mediainfo")
			  (specification->package "ffmpegthumbnailer")
			  (specification->package "poppler")
			  (specification->package "atool")
			  (specification->package "unzip")
			  (specification->package "odt2txt")
			  (specification->package "jq")
			  (specification->package "emacs-rainbow-delimiters")
			  (specification->package "emacs-visual-fill-column")
			  (specification->package "emacs-lsp-mode")
			  (specification->package "emacs-company")
			  (specification->package "emacs-flycheck")
			  (specification->package "emacs-lsp-ui")
			  (specification->package "emacs-lsp-ivy")
			  (specification->package "emacs-vterm")
			  (specification->package "emacs-lsp-treemacs")
			  (specification->package "emacs-yasnippet")
			  (specification->package "emacs-geiser")
			  (specification->package "emacs-geiser-guile")
			  (specification->package "emacs-sly")
			  (specification->package "emacs-lua-mode")
			  (specification->package "emacs-json-mode")
			  (specification->package "emacs-org")
			  (specification->package "emacs-org-bullets")
			  (specification->package "emacs-evil")
			  (specification->package "emacs-projectile")
			  (specification->package "emacs-counsel-projectile")
			  (specification->package "emacs-evil-collection")
			  (specification->package "emacs-magit")
			  (specification->package "emacs-helpful")
			  (specification->package "emacs-general")
			  (specification->package "emacs-use-package")
			  (specification->package "emacs-which-key")
			  (specification->package "emacs-ivy-rich")
			  (specification->package "emacs-counsel")
			  (specification->package "emacs-diminish")
			  (specification->package "emacs-ivy")
			  (specification->package "emacs-doom-modeline")
              (specification->package "ncurses")
              (specification->package "ripgrep")
              (specification->package "vim")
			  (specification->package "font-iosevka-term")
			  (specification->package "font-nerd-symbols")
			  (specification->package "font-google-noto-emoji")
			  (specification->package "font-nerd-jetbrains-mono")
			  (specification->package "emacs-all-the-icons")
  			  (specification->package "emacs-all-the-icons-dired")
			  (specification->package "sbcl")
			  (specification->package "lua")
			  (specification->package "lua-language-server")
			  (specification->package "python")
			  (specification->package "python-lsp-server")
			  (specification->package "ruff")
			  (specification->package "shellcheck")
			  (specification->package "shfmt")
			  (specification->package "clang")
			  (specification->package "gcc-toolchain")
			  (specification->package "make")
			  (specification->package "gdb")
			  (specification->package "pkg-config")
			  (specification->package "emacs-all-the-icons-ibuffer")
			  (specification->package "xwallpaper")
			  (specification->package "picom")
			  (specification->package "xrandr"))
                    %base-packages))

  ;; Below is the list of system services.  To search for available
  ;; services, run 'guix system search KEYWORD' in a terminal.
  (services
   (modify-services
    (append (list

                  ;; To configure OpenSSH, pass an 'openssh-configuration'
                  ;; record as a second argument to 'service' below.
                  (service openssh-service-type)
                  (service bluetooth-service-type)
                  (service xorg-server-service-type
                   (xorg-configuration (keyboard-layout keyboard-layout)))
                  (service startx-command-service-type
                   (xorg-configuration (keyboard-layout keyboard-layout))))

            ;; This is the default list of services we
            ;; are appending to.
            %desktop-services)
    (delete gdm-service-type)
    (delete pulseaudio-service-type)
    (mingetty-service-type
     config => (if (string=? (mingetty-configuration-tty config) "tty1")
                   (mingetty-configuration
                    (inherit config)
                    (auto-login "skydive420dz")
                    (clear-on-logout? #t)
                    (print-issue #f)
                    (print-hostname #f))
                   config))

    (guix-service-type
     config => (guix-configuration
                (inherit config)
                (extra-options '("--cores=4"
                                 "--max-jobs=1"))))

    (elogind-service-type
     config => (elogind-configuration
                (inherit config)
                (idle-action 'ignore)
                (handle-lid-switch 'ignore)
                (handle-lid-switch-external-power 'ignore)
                (handle-suspend-key 'ignore)))))
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets (list "/boot/efi"))
                (theme (grub-theme
                        (resolution '(3440 . 1440))
                        (gfxmode '("3440x1440" "2560x1440" "1920x1080" "auto"))))
                (keyboard-layout keyboard-layout)))
  (swap-devices (list (swap-space
                        (target (uuid
                                 "2083a12f-123c-4893-8b64-1358fe666180")))))

  ;; The list of file systems that get "mounted".  The unique
  ;; file system identifiers there ("UUIDs") can be obtained
  ;; by running 'blkid' in a terminal.
  (file-systems (cons* (file-system
                         (mount-point "/boot/efi")
                         (device (uuid "F476-0B09"
                                       'fat16))
                         (type "vfat"))
                       (file-system
                         (mount-point "/")
                         (device (uuid
                                  "e4279482-6b04-4f8b-8dab-3f70ae3daa65"
                                  'ext4))
                         (type "ext4"))
                       (file-system
                         (mount-point "/home")
                         (device (uuid
                                  "70807a48-75ba-4fa2-a760-64e930805665"
                                  'ext4))
                         (type "ext4")) %base-file-systems)))
))
