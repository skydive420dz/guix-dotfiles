;; User-level services for guixpc.
;;
;; The system configuration owns hardware services and system packages.
;; Guix Home owns session services such as PipeWire.

(use-modules (gnu home)
             (gnu home services)
             (gnu home services desktop)
             (gnu home services shells)
             (gnu home services sound)
             (gnu services)
             (guix gexp))

(define %repo-root
  (dirname (dirname (dirname (current-filename)))))

(define %fish-config
  (plain-file
   "sk-fish-config.fish"
   "
set -g fish_greeting
set -gx EDITOR \"emacsclient -t -a 'emacs -nw'\"
set -gx VISUAL \"emacsclient -n -a emacs\"
set -gx PAGER less

function __sk_shell_greeter
    status is-interactive
    or return

    set -q SK_FASTFETCH_SHOWN
    and return

    command -q fastfetch
    or return

    set -gx SK_FASTFETCH_SHOWN 1
    fastfetch
    echo
end

function __sk_prompt_pwd
    set -l path (prompt_pwd)
    set path (string replace -r '^~' ' ~' $path)
    set path (string replace 'Documents' '󰈙' $path)
    set path (string replace 'Downloads' '' $path)
    set path (string replace 'Music' '󰝚' $path)
    set path (string replace 'Pictures' '' $path)
    set path (string replace 'Videos' '󰕧' $path)
    set path (string replace 'guix-dotfiles' '' $path)
    echo $path
end

function __sk_git_branch
    command git symbolic-ref --quiet --short HEAD 2>/dev/null
    or command git rev-parse --short HEAD 2>/dev/null
end

function __sk_git_status
    command git rev-parse --is-inside-work-tree >/dev/null 2>/dev/null
    or return

    set -l git_state (command git status --porcelain 2>/dev/null)
    if test -z \"$git_state\"
        echo '󱓏'
    else
        echo '󰷈'
    end
end

function fish_prompt
    set -l last_status $status
    set -l branch (__sk_git_branch)
    set -l git_status (__sk_git_status)

    set_color normal
    set_color --background=30343a b4c0c8
    echo -n ' '(__sk_prompt_pwd)' '
    set_color normal

    if test -n \"$branch\"
        echo -n ' '
        set_color 89b4fa
        echo -n '󰊢 '$branch' '
        set_color 8a949e
        echo -n $git_status' '
        set_color normal
    end

    echo

    if test $last_status -eq 0
        set_color a6d189
    else
        set_color e78284
    end
    echo -n '❯ '
    set_color normal
end

function fish_right_prompt
end

__sk_shell_greeter
"))

(define %repo-link-activation
  #~(begin
      (use-modules ((guix build utils) #:select (mkdir-p)))

      (define home (getenv "HOME"))
      (define repo #$%repo-root)

      (define (symlink-path? path)
        (let ((stat (false-if-exception (lstat path))))
          (and stat
               (eq? (stat:type stat) 'symlink))))

      (define (ensure-repo-link target source)
        (let* ((target-path (string-append home "/" target))
               (source-path (string-append repo "/" source))
               (parent (dirname target-path)))
          (mkdir-p parent)
          (cond
           ((and (symlink-path? target-path)
                 (string=? (readlink target-path) source-path))
            #t)
           ((symlink-path? target-path)
            (delete-file target-path)
            (symlink source-path target-path)
            (format #t "Updated symlink ~a -> ~a~%" target-path source-path))
           ((not (file-exists? target-path))
            (symlink source-path target-path)
            (format #t "Created symlink ~a -> ~a~%" target-path source-path))
           (else
            (format #t "Keeping existing non-symlink ~a~%" target-path)))))

      (for-each
       (lambda (link)
         (ensure-repo-link (car link) (cadr link)))
       '((".bash_profile" "shell/bash_profile")
         (".bashrc" "shell/bashrc")
         (".zprofile" "shell/zprofile")
         (".exwm" "emacs/exwm-loader.el")
         (".emacs.d/init.el" "emacs/init.el")
         (".emacs.d/exwm.el" "emacs/exwm.el")
         (".gdbinit" "gdb/gdbinit")
         (".guile" "guile/guile")
         (".Xdefaults" "x11/Xdefaults")
         (".config/kitty/kitty.conf" "kitty/kitty.conf")
         (".config/ranger/rc.conf" "ranger/rc.conf")
         (".config/ranger/rifle.conf" "ranger/rifle.conf")
         (".config/ranger/scope.sh" "ranger/scope.sh")))))

(home-environment
 (services
  (list
   (simple-service 'sk-repo-dotfile-links
                   home-activation-service-type
                   %repo-link-activation)
   (service home-fish-service-type
            (home-fish-configuration
             (config (list %fish-config))
             (aliases
              '(("ls" . "ls -p --color=auto")
                ("ll" . "ls -l")
                ("grep" . "grep --color=auto")
                ("gsr" . "sudo $HOME/.config/guix/current/bin/guix system reconfigure $HOME/.config/guix/systems/guixpc.scm --substitute-urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://substitutes.nonguix.org'")
                ("ghr" . "$HOME/.config/guix/current/bin/guix home reconfigure $HOME/.config/guix/home.scm --substitute-urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://substitutes.nonguix.org'")))))
   (service home-dbus-service-type)
   (service home-pipewire-service-type
            (home-pipewire-configuration
             (enable-pulseaudio? #t))))))
