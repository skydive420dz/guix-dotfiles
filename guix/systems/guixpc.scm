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
             (nonguix transformations))
(use-service-modules cups desktop networking ssh xorg)

((nonguix-transformation-guix)
 ((nonguix-transformation-linux)
  (operating-system
  (locale "en_US.utf8")
  (timezone "America/New_York")
  (keyboard-layout (keyboard-layout "us"))
  (host-name "guixpc")

  (kernel-arguments
   (cons* "modprobe.blacklist=pcspkr"
          %default-kernel-arguments))

  ;; The list of user accounts ('root' is implicit).
  (users (cons* (user-account
                  (name "skydive420dz")
                  (comment "Rafael Oliveira")
                  (group "users")

                  (home-directory "/home/skydive420dz")
                  (supplementary-groups '("wheel" "netdev" "audio" "video")))
                %base-user-accounts))

  ;; Packages installed system-wide.  Users can also install packages
  ;; under their own account: use 'guix search KEYWORD' to search
  ;; for packages and 'guix install PACKAGE' to install a package.
  (packages (append (list (specification->package "curl")
                          (specification->package "emacs")
                          (specification->package "emacs-exwm")
                          (specification->package
                           "emacs-desktop-environment")
                          (specification->package "git")
			  (specification->package "kitty")
			  (specification->package "ungoogled-chromium")
			  (specification->package "emacs-magit")
			  (specification->package "emacs-use-package")
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
			  (specification->package "emacs-all-the-icons-ibuffer")
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
                  (set-xorg-configuration
                   (xorg-configuration (keyboard-layout keyboard-layout))))

            ;; This is the default list of services we
            ;; are appending to.
            %desktop-services)
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
