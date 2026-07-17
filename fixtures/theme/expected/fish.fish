# SYNTHETIC FIXTURE - DO NOT INSTALL
# schema=1 palette=synthetic fixture only
# Generated Fish syntax, pager, and prompt color adapter.
set -g -- fish_color_normal 'ffffff'
set -g -- fish_color_command '00ff87'
set -g -- fish_color_keyword '00d7ff' '--bold'
set -g -- fish_color_quote 'ffd700'
set -g -- fish_color_redirection '00d7ff' '--bold'
set -g -- fish_color_end '00ff87'
set -g -- fish_color_error 'ff6b6b'
set -g -- fish_color_param 'ffffff'
set -g -- fish_color_valid_path 'ffffff' '--underline'
set -g -- fish_color_option '00d7ff'
set -g -- fish_color_comment 'd0d0d0' '--italics'
set -g -- fish_color_selection 'ffffff' '--background=005f87' '--bold'
set -g -- fish_color_operator '00d7ff'
set -g -- fish_color_escape 'ffd700'
set -g -- fish_color_autosuggestion 'a0a0a0'
set -g -- fish_color_cancel 'ff6b6b' '--reverse'
set -g -- fish_color_search_match 'ffffff' '--background=005f87' '--bold'
set -g -- fish_color_history_current 'ffffff' '--background=005f87' '--bold'
set -g -- fish_color_host 'd0d0d0'
set -g -- fish_color_host_remote 'ffd700'
set -g -- fish_color_status 'ff6b6b'
set -g -- fish_color_cwd '00ff87'
set -g -- fish_color_cwd_root 'ff6b6b'
set -g -- fish_color_user '00ff87'
set -g -- fish_color_background '--background=101010'
set -g -- fish_color_statement_terminator '00d7ff'
set -g -- fish_pager_color_progress '000000' '--background=00d7ff' '--bold'
set -g -- fish_pager_color_background '--background=181818'
set -g -- fish_pager_color_prefix '00d7ff' '--bold' '--underline'
set -g -- fish_pager_color_completion 'ffffff'
set -g -- fish_pager_color_description 'd0d0d0' '--italics'
set -g -- fish_pager_color_secondary_background '--background=303030'
set -g -- fish_pager_color_secondary_prefix '00d7ff' '--bold'
set -g -- fish_pager_color_secondary_completion 'ffffff'
set -g -- fish_pager_color_secondary_description 'd0d0d0' '--italics'
set -g -- fish_pager_color_selected_background '--background=005f87'
set -g -- fish_pager_color_selected_prefix 'ffffff' '--background=005f87' '--bold'
set -g -- fish_pager_color_selected_completion 'ffffff' '--background=005f87'
set -g -- fish_pager_color_selected_description 'ffffff' '--background=005f87' '--italics'
set -g -- __sk_theme_prompt_path 'ffffff'
set -g -- __sk_theme_prompt_path_background '--background=303030'
set -g -- __sk_theme_prompt_git_branch '00d7ff'
set -g -- __sk_theme_prompt_git_status 'd0d0d0'
set -g -- __sk_theme_prompt_success '00ff87'
set -g -- __sk_theme_prompt_error 'ff6b6b'

function fish_prompt
    set -l last_status $status
    set -l branch (__sk_git_branch)
    set -l git_status (__sk_git_status)

    set_color normal
    set_color $__sk_theme_prompt_path_background $__sk_theme_prompt_path
    echo -n ' '(__sk_prompt_pwd)' '
    set_color normal

    if test -n "$branch"
        echo -n ' '
        set_color $__sk_theme_prompt_git_branch
        echo -n '󰊢 '$branch' '
        set_color $__sk_theme_prompt_git_status
        echo -n $git_status' '
        set_color normal
    end

    echo

    if test $last_status -eq 0
        set_color $__sk_theme_prompt_success
    else
        set_color $__sk_theme_prompt_error
    end
    echo -n '❯ '
    set_color normal
end

function fish_right_prompt
end
