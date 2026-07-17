set -g fish_greeting
set -gx EDITOR "emacsclient -t -a 'emacs -nw'"
set -gx VISUAL "emacsclient -n -a emacs"
set -gx BROWSER chromium
set -gx PAGER less

function __sk_import_home_environment_for_ssh
    status is-login
    and return

    set -q SSH_CONNECTION
    or return

    set -l home_bin "$HOME/.guix-home/profile/bin"
    set -q PATH[1]
    and test "$PATH[1]" = "$home_bin"
    and return

    set -l fenv_functions "$HOME/.guix-home/profile/share/fish/functions"
    test -r "$HOME/.profile"
    or return
    test -r "$fenv_functions/fenv.fish"
    or return
    test -r "$fenv_functions/fenv.main.fish"
    or return

    set --prepend fish_function_path "$fenv_functions"
    source "$fenv_functions/fenv.main.fish"
    source "$fenv_functions/fenv.fish"
    if not fenv source "$HOME/.profile"
        set -e fish_function_path[1]
        return 1
    end
    set -e fish_function_path[1]
end

__sk_import_home_environment_for_ssh

function sk-start-exwm
    test -z "$SSH_CONNECTION"
    or begin
        echo "EXWM: refusing to start from SSH" >&2
        return 1
    end

    test -z "$DISPLAY"
    or begin
        echo "EXWM: DISPLAY is already set" >&2
        return 1
    end

    test -z "$WAYLAND_DISPLAY"
    or begin
        echo "EXWM: WAYLAND_DISPLAY is already set" >&2
        return 1
    end

    set -l current_tty (tty 2>/dev/null)
    test "$current_tty" = "/dev/tty1"
    or begin
        echo "EXWM: start from the local tty1 recovery shell" >&2
        return 1
    end

    set -l session_runner "$HOME/Projects/guix-dotfiles/scripts/exwm-session"
    test -x "$session_runner"
    or begin
        echo "EXWM: session runner is unavailable: $session_runner" >&2
        return 1
    end

    command "$session_runner"
    set -l exwm_status $status
    if test $exwm_status -ne 0
        echo "EXWM: returned to tty1 recovery shell" >&2
    end
    return $exwm_status
end

function __sk_start_exwm_from_tty
    status is-login
    or return

    status is-interactive
    or return

    test -z "$SSH_CONNECTION"
    or return

    test -z "$DISPLAY"
    or return

    test -z "$WAYLAND_DISPLAY"
    or return

    set -l current_tty (tty 2>/dev/null)
    test "$current_tty" = "/dev/tty1"
    or return

    sk-start-exwm
end

__sk_start_exwm_from_tty

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
    if test -z "$git_state"
        echo '󱓏'
    else
        echo '󰷈'
    end
end

__sk_shell_greeter
