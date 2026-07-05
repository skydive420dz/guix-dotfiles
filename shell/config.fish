set -g fish_greeting
set -gx EDITOR "emacsclient -t -a 'emacs -nw'"
set -gx VISUAL "emacsclient -n -a emacs"
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
    if test -z "$git_state"
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

    if test -n "$branch"
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
