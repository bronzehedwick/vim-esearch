let s:default_mappings = {
      \ 't':     '<Plug>(esearch-tab)',
      \ 'T':     '<Plug>(esearch-tab-s)',
      \ 'i':     '<Plug>(esearch-split)',
      \ 'I':     '<Plug>(esearch-split-s)',
      \ 's':     '<Plug>(esearch-vsplit)',
      \ 'S':     '<Plug>(esearch-vsplit-s)',
      \ 'R':     '<Plug>(esearch-reload)',
      \ '<Enter>':  '<Plug>(esearch-open)',
      \ 'o':     '<Plug>(esearch-open)',
      \ '<C-n>': '<Plug>(esearch-next)',
      \ '<C-p>': '<Plug>(esearch-prev)',
      \ }
" The first line. It contains information about the number of results
let s:header = '%d matches'
let s:mappings = {}
let s:file_entry = '^\s\+\d\+\s\+.*'

" TODO wrap arguments with hash
fu! esearch#out#win#init(adapter, backend, request, exp, bufname, cwd, opencmd) abort
  call s:find_or_create_buf(a:bufname, a:opencmd)

  augroup ESearchWinAutocmds
    au! * <buffer>
    au BufLeave    <buffer> let  &updatetime = b:updatetime_backup
    au BufEnter    <buffer> let  b:updatetime_backup = &updatetime |
          \ let &updatetime = float2nr(g:esearch.updatetime)
    call esearch#backend#{a:backend}#init_events()
  augroup END

  call s:init_mappings()
  call s:init_commands()


  let b:updatetime_backup = &updatetime
  let &updatetime = float2nr(g:esearch.updatetime)

  setlocal ft=esearch
  " Refresh match highlight
  if g:esearch.highlight_match
    " matchdelete is moved outside in case of dynamic .highlight_match change
    if exists('b:esearch')
      try
        call matchdelete(b:esearch._match_highlight_id)
      catch /E803:/
      endtry
    endif

    let match_highlight_id = matchadd('EsearchMatch', a:exp.vim_match, -1)
  endif

  let b:esearch = {
        \ 'out':                 'win',
        \ 'exp':                 a:exp,
        \ 'adapter':             a:adapter,
        \ 'backend':             a:backend,
        \ 'request':             a:request,
        \ 'parsed':              [],
        \ 'parsed_count':        0,
        \ 'unparsed':            [],
        \ 'cwd':                 a:cwd,
        \ 'prev_filename':       '',
        \ '_lines_iterator':     0,
        \ '_columns':            {},
        \ '_match_highlight_id': match_highlight_id,
        \ '_last_update_time':   esearch#util#timenow(),
        \ '__broken_results':    [],
        \}

  let &iskeyword = g:esearch.wordchars
  setlocal noreadonly
  setlocal modifiable
  exe '1,$d'
  call setline(1, printf(s:header, b:esearch._lines_iterator))
  setlocal readonly
  setlocal nomodifiable
  setlocal noswapfile
  setlocal nonumber
  setlocal buftype=nofile
  setlocal bufhidden=hide
endfu

" TODO add highlight of the replaced text
fu! esearch#out#win#substitute(args, from, to)
  let line = a:from
  let limit = a:from > a:to ? a:from + 1 : a:to + 1

  let pushed = 0
  let root = tabpagenr()
  let last_modified_tab = tabpagenr()
  let opened_files = {}
  let prev_filename = ''
  let disable_autocmd = 'noautocmd '

  while line < limit
    exe line
    " call esearch#log({'line': line, 'line(".")': line('.'), 'getline(line)': getline(line),
    "       \ '=~s:file_entry': getline(line) =~# s:file_entry, 'root': root, 
    "       \ 'tabpagenr': tabpagenr(), 'pushed': pushed})
    redraw!
    if getline(line) =~# s:file_entry
      let not_found = 0

      let filename = s:filename()
      " call esearch#log({'filename': filename, 'opened_files': opened_files, 'line_number': s:line_number()})
      let already_opened = has_key(opened_files, filename)
      if already_opened
        exe disable_autocmd.'tabn'.opened_files[filename].'|'.s:line_number()
      else
        call s:open('$tabnew')
        let opened_files[filename] = tabpagenr()
      endif

      try
        exe 's'a:args
      catch /E486:/
        let not_found = 1
      catch
        echo 'Error'
      endtry

      if not_found && !already_opened
        let useless_tab = tabpagenr() 
        exe disable_autocmd.'tabn'.root
        exe disable_autocmd.'tabclose'.useless_tab
      else
        let last_modified_tab = tabpagenr()
        exe disable_autocmd.'tabn'.root
        if !pushed
          let pushed = 1
          " Push current search tab to the right (penultimate position,
          " before the newly opened) for more convenience
          let root = tabpagenr('$') - 1
          exe disable_autocmd.'tabm '.(root - 1 )
        endif
      endif

    endif
    let line += 1
  endwhile

  exe 'tabn'last_modified_tab
endfu

fu! s:find_or_create_buf(bufname, opencmd) abort
  let bufnr = bufnr('^'.a:bufname.'$')
  if bufnr == bufnr('%')
    return 0
  elseif bufnr > 0
    let buf_loc = s:find_buf(bufnr)
    if empty(buf_loc)
      silent exe a:opencmd.'|b ' . bufnr
    else
      silent exe 'tabn ' . buf_loc[0]
      exe buf_loc[1].'winc w'
    endif
  else
    silent  exe a:opencmd.'|file '.a:bufname
  endif
endfu

fu! s:find_buf(bufnr) abort
  for tabnr in range(1, tabpagenr('$'))
    if tabpagenr() == tabnr | continue | endif
    let buflist = tabpagebuflist(tabnr)
    if index(buflist, a:bufnr) >= 0
      for winnr in range(1, tabpagewinnr(tabnr, '$'))
        if buflist[winnr - 1] == a:bufnr | return [tabnr, winnr] | endif
      endfor
    endif
  endfor

  return []
endf

fu! esearch#out#win#update(data, ...) abort
  let ignore_batches = a:0 && a:1
  let b:esearch.unparsed = a:data

  call s:extend_results()

  let parsed_count = b:esearch.parsed_count
  if parsed_count > b:esearch._lines_iterator
    if ignore_batches || parsed_count - b:esearch._lines_iterator - 1 <= g:esearch.batch_size
      let parsed_range = [b:esearch._lines_iterator, parsed_count - 1]
      let b:esearch._lines_iterator = parsed_count
    else
      let parsed_range = [b:esearch._lines_iterator, b:esearch._lines_iterator + g:esearch.batch_size - 1]
      let b:esearch._lines_iterator += g:esearch.batch_size
    endif

    setlocal noreadonly
    setlocal modifiable
    call s:render_results(parsed_range)
    call setline(1, printf(s:header, b:esearch._lines_iterator))
    setlocal readonly
    setlocal nomodifiable
    setlocal nomodified
  endif

  " exe g:esearch.update_statusline_cmd
  let b:esearch._last_update_time = esearch#util#timenow()
endfu

fu! s:extend_results() abort
  if len(b:esearch.parsed) < len(b:esearch.unparsed) && !empty(b:esearch.unparsed)
    let from = len(b:esearch.parsed)
    let to = len(b:esearch.unparsed)-1
    let parsed = esearch#adapter#{b:esearch.adapter}#parse_results(b:esearch.unparsed, from, to, b:esearch.__broken_results)
    " TODO replace b:esearch.parsed with b:esearch.parsed_count
    call extend(b:esearch.parsed, parsed)
    let b:esearch.parsed_count = len(b:esearch.parsed)
  endif
endfu

fu! s:render_results(parsed_range) abort
  let line = line('$') + 1
  let i = a:parsed_range[0]
  let limit = a:parsed_range[1] + 1
  while i < limit
    let fname    = substitute(b:esearch.parsed[i].fname, b:esearch.cwd.'/', '', '')
    let context  = s:context(b:esearch.parsed[i].text)

    if fname !=# b:esearch.prev_filename
      call setline(line, '')
      let line += 1
      call setline(line, fname)
      let line += 1
    endif
    call setline(line, ' '.printf('%3d', b:esearch.parsed[i].lnum).' '.context)
    let b:esearch._columns[line] = b:esearch.parsed[i].col
    let b:esearch.prev_filename = fname
    let line += 1
    let i    += 1
  endwhile
endfu

fu! s:context(line)
  return esearch#util#btrunc(a:line,
                           \ match(a:line, b:esearch.exp.vim),
                           \ g:esearch.context_width.l,
                           \ g:esearch.context_width.r)

endfu

fu! esearch#out#win#map(map, plug) abort
  let s:mappings[a:map] = a:plug
endfu

fu! s:init_commands() abort
  command! -nargs=1 -range=0 -bar -buffer ESubstitute
        \ call esearch#out#win#substitute(<q-args>, <line1>, <line2>)

  if exists(':E') != 2
    command! -nargs=1 -range=0 -bar -buffer E
          \ call esearch#out#win#substitute(<q-args>, <line1>, <line2>)
  elseif exists(':ES') != 2
    command! -nargs=1 -range=0 -bar -buffer ES
          \ call esearch#out#win#substitute(<q-args>, <line1>, <line2>)
  endif
endfu

fu! s:init_mappings() abort
  nnoremap <silent><buffer> <Plug>(esearch-tab)       :<C-U>call <sid>open('tabnew')<cr>
  nnoremap <silent><buffer> <Plug>(esearch-tab-s)     :<C-U>call <SID>open('tabnew', 'tabprevious')<CR>
  nnoremap <silent><buffer> <Plug>(esearch-split)     :<C-U>call <SID>open('new')<CR>
  nnoremap <silent><buffer> <Plug>(esearch-split-s)   :<C-U>call <SID>open('new', 'wincmd p')<CR>
  nnoremap <silent><buffer> <Plug>(esearch-vsplit)    :<C-U>call <SID>open('vnew')<CR>
  nnoremap <silent><buffer> <Plug>(esearch-vsplit-s)  :<C-U>call <SID>open('vnew', 'wincmd p')<CR>
  nnoremap <silent><buffer> <Plug>(esearch-open)      :<C-U>call <SID>open('edit')<CR>
  nnoremap <silent><buffer> <Plug>(esearch-reload)    :<C-U>call esearch#_start(b:esearch.exp, b:esearch.cwd)<CR>
  nnoremap <silent><buffer> <Plug>(esearch-prev)      :<C-U>sil exe <SID>jump(0)<CR>
  nnoremap <silent><buffer> <Plug>(esearch-next)      :<C-U>sil exe <SID>jump(1)<CR>
  nnoremap <silent><buffer> <Plug>(esearch-Nop) <Nop>

  call extend(s:mappings, s:default_mappings, 'keep')
  for map in keys(s:mappings)
    exe 'nmap <buffer> ' . map . ' ' . s:mappings[map]
  endfor
endfu

fu! s:open(cmd, ...) abort
  let fname = s:filename()
  if !empty(fname)
    let ln = s:line_number()
    let col = get(b:esearch._columns, line('.'), 1)
    let cmd = (a:0 ? 'noautocmd ' :'') . a:cmd
    exe a:cmd . ' ' . fnameescape(b:esearch.cwd . '/' . fname)
    call cursor(ln, col)
    norm! zz
    if a:0 | exe a:1 | endif
  endif
endfu

fu! s:filename() abort
  let lnum = search('^\%>2l[^ ]', 'bcWn')
  if lnum == 0
    let lnum = search('^\%>2l[^ ]', 'cWn')
    if lnum == 0 | return '' | endif
  endif

  let filename = matchstr(getline(lnum), '^\zs[^ ].*')
  if empty(filename)
    return ''
  else
    return substitute(filename, '^\./', '', '')
  endif
endfu

fu! s:line_number() abort
  let pattern = '^\%>1l\s\+\d\+.*'

  if line('.') < 3 || match(getline('.'), '^[^ ].*') >= 0
    let lnum = search(pattern, 'cWn')
  else
    let lnum = search(pattern, 'bcWn')
  endif

  return matchstr(getline(lnum), '^\s\+\zs\d\+\ze.*')
endfu

fu! s:jump(downwards) abort
  let pattern = s:file_entry
  let last_line = line('$')

  if a:downwards
    " If one result - move cursor on it, else - move the next
    let pattern .= last_line <= 4 ? '\%>3l' : '\%>4l'
    call search(pattern, 'W')
  else
    " If cursor is in gutter between result groups(empty line)
    if '' ==# getline(line('.'))
      call search(pattern, 'Wb')
    endif
    " If no results behind - jump the first, else - previous
    call search(pattern, line('.') < 4 ? '' : 'Wbe')
  endif

  call search('^', 'Wb', line('.'))
  " If there is no results - do nothing
  if last_line == 1
    return ''
  else
    " search the start of the line
    return 'norm! ww'
  endif
endfu

fu! esearch#out#win#on_finish() abort
  au! ESearchWinAutocmds * <buffer>
  unlet b:esearch.parsed b:esearch.unparsed
  let &updatetime = float2nr(b:updatetime_backup)

  setlocal noreadonly
  setlocal modifiable
  call setline(1, getline(1) . '. Finished.' )
  setlocal readonly
  setlocal nomodifiable
  setlocal nomodified
endfu
