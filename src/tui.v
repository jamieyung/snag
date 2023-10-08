module main

import math
import os
import term.ui as tui

const (
	ffmpeg_exe = '/mnt/c/ProgramData/chocolatey/bin/ffmpeg.exe'
	vlc_exe    = '/mnt/c/Program\\ Files\\ \\(x86\\)/VideoLan/VLC/vlc.exe'
	obs_dir    = '/mnt/d/clips/OBS'
	fbclip_ext = '.fb.mp4'
)

enum FilterMode {
	all
	no_fbclips
	only_fbclips
	only_processing
	only_new_fbclips
}

fn (f FilterMode) next() FilterMode {
	match f {
		.all { return .no_fbclips }
		.no_fbclips { return .only_fbclips }
		.only_fbclips { return .only_processing }
		.only_processing { return .only_new_fbclips }
		.only_new_fbclips { return .all }
	}
}

struct App {
mut:
	tui                &tui.Context = unsafe { nil }
	filter_mode        FilterMode   = .all
	cursor_y           int
	scroll_y           int
	all_files          []string
	files              []string
	processing_files   map[string]bool
	processing_fbclips map[string]bool
	new_fbclips        map[string]bool
	n_secs             int
}

fn main() {
	mut app := &App{
		cursor_y: 0
		scroll_y: 0
		processing_files: map[string]bool{}
		processing_fbclips: map[string]bool{}
		new_fbclips: map[string]bool{}
		n_secs: 25
	}
	refresh_file_lists(mut app)
	app.tui = tui.init(
		user_data: app
		cleanup_fn: cleanup
		event_fn: event
		frame_fn: frame
		buffer_size: 512
		frame_rate: 60
	)
	app.tui.run()!
}

fn event(e &tui.Event, mut app App) {
	if e.typ != .key_down {
		return
	}

	if e.modifiers == .ctrl {
		handle_ctrl_key(e, mut app)
	} else if !(e.modifiers.all(.ctrl | .shift | .alt)) { // no modifiers
		handle_normal_key(e, mut app)
	}
}

fn handle_ctrl_key(e &tui.Event, mut app App) {
	match e.code {
		.u { // scroll up a screen
			move_cursor_up(app.tui.window_height, mut app)
		}
		.d { // scroll down a screen
			move_cursor_down(app.tui.window_height, mut app)
		}
		else {}
	}
}

fn handle_normal_key(e &tui.Event, mut app App) {
	match e.code {
		.escape, .q { // quit
			exit(0)
		}
		.j, .down { // move cursor down
			move_cursor_down(1, mut app)
		}
		.k, .up { // move cursor up
			move_cursor_up(1, mut app)
		}
		.space { // play the file in VLC starting -{app.n_secs} from the end
			file := app.files[app.scroll_y + app.cursor_y]
			out_secs := get_file_out_secs(file)
			start_time := math.max(0, out_secs - app.n_secs)
			exec('cd ${obs_dir} && ${vlc_exe} ${file} --start-time ${start_time}')
		}
		.enter { // play the file in VLC from the start
			file := app.files[app.scroll_y + app.cursor_y]
			exec('cd ${obs_dir} && ${vlc_exe} ${file}')
		}
		.r { // refresh file list
			refresh_file_lists(mut app)
		}
		.o { // open file explorer
			file := app.files[app.scroll_y + app.cursor_y]
			exec('cd ${obs_dir} && explorer.exe /select,"${file}"')
		}
		.c { // create a clip using the default of the last {app.n_secs} secs
			file := app.files[app.scroll_y + app.cursor_y]
			if app.processing_files[file] {
				// don't process files already being processed
				return
			}
			if is_fbclip(file) {
				// don't process files that are already fbclips themselves
				return
			}
			spawn create_clip(file, mut app)
		}
		.m {
			app.filter_mode = app.filter_mode.next()
			refresh_filter_list(mut app)
		}
		._1 {
			app.filter_mode = .all
			refresh_filter_list(mut app)
		}
		._2 {
			app.filter_mode = .no_fbclips
			refresh_filter_list(mut app)
		}
		._3 {
			app.filter_mode = .only_fbclips
			refresh_filter_list(mut app)
		}
		._4 {
			app.filter_mode = .only_processing
			refresh_filter_list(mut app)
		}
		._5 {
			app.filter_mode = .only_new_fbclips
			refresh_filter_list(mut app)
		}
		._7 {
			app.n_secs = 25
		}
		._8 {
			app.n_secs = 20
		}
		.minus {
			app.n_secs = math.max(1, app.n_secs - 1)
		}
		.plus {
			app.n_secs++
		}
		else {}
	}
}

fn move_cursor_down(delta int, mut app App) {
	app.cursor_y += delta
	if app.files.len < app.tui.window_height { // fewer files than vertical lines
		app.scroll_y = 0
		app.cursor_y = math.min(app.files.len - 1, app.cursor_y)
	} else { // more files than vertical lines
		if app.cursor_y >= app.tui.window_height {
			app.cursor_y = app.tui.window_height - 1
			app.scroll_y = math.min(app.files.len - app.tui.window_height, app.scroll_y + delta)
		}
	}
}

fn move_cursor_up(delta int, mut app App) {
	app.cursor_y -= delta
	if app.cursor_y < 0 {
		app.cursor_y = 0
		app.scroll_y = math.max(0, app.scroll_y - delta)
	}
}

fn create_clip(file string, mut app App) {
	app.processing_files[file] = true
	out_file := '${file}${fbclip_ext}'
	app.processing_fbclips[out_file] = true
	out_secs := get_file_out_secs(file)
	in_secs := math.max(0, out_secs - app.n_secs)

	// create the file and refresh the file list
	exec('cd ${obs_dir} && touch ${out_file}')
	refresh_file_lists(mut app)

	exec_in_new_process(ffmpeg_exe, [
		'-y',
		'-i',
		file,
		'-ss',
		'00:00:${in_secs}',
		'-to',
		'00:00:${out_secs}',
		'-vf',
		'scale=iw/2.5:ih/2.5',
		out_file,
	], obs_dir)
	app.processing_files.delete(file)
	app.processing_fbclips.delete(out_file)
	app.new_fbclips[out_file] = true
	refresh_file_lists(mut app)
}

fn get_file_out_secs(file string) int {
	out_secs_str := exec('cd ${obs_dir} && ffprobe.exe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 ${file}')
	return out_secs_str.int()
}

fn refresh_file_lists(mut app App) {
	mut files := os.ls(obs_dir) or {
		println(err)
		return
	}
	files.reverse_in_place() // we want the first element in the array to be the most recent
	app.all_files = files
	refresh_filter_list(mut app)
}

fn refresh_filter_list(mut app App) {
	match app.filter_mode {
		.all {
			app.files = app.all_files
		}
		.no_fbclips {
			filtered := app.all_files.filter(fn (file string) bool {
				return !is_fbclip(file)
			})
			app.files = filtered
		}
		.only_fbclips {
			filtered := app.all_files.filter(fn (file string) bool {
				return is_fbclip(file)
			})
			app.files = filtered
		}
		.only_processing {
			mut filtered := []string{}
			for file in app.all_files {
				if app.processing_files[file] || app.processing_fbclips[file] {
					filtered << file
				}
			}
			app.files = filtered
		}
		.only_new_fbclips {
			mut filtered := []string{}
			for file in app.all_files {
				if app.new_fbclips[file] {
					filtered << file
				}
			}
			app.files = filtered
		}
	}
}

fn frame(mut app App) {
	ensure_cursor_and_scroll_y_are_in_bounds(mut app)
	draw(mut app)
}

fn ensure_cursor_and_scroll_y_are_in_bounds(mut app App) {
	if app.files.len < app.tui.window_height {
		app.cursor_y = math.max(0, math.min(app.files.len - 1, app.cursor_y))
		app.scroll_y = 0
	} else {
		app.cursor_y = math.max(0, math.min(app.tui.window_height - 1, app.cursor_y))
		app.scroll_y = math.min(app.files.len - app.tui.window_height, app.scroll_y)
	}
}

fn draw(mut app App) {
	app.tui.clear()
	app.tui.show_cursor()

	h := math.min(app.tui.window_height, app.files.len)

	draw_debug_info(60, 1, mut app)
	draw_keyboard_shortcuts(60, 7, mut app)

	for i := 0; i < h; i++ {
		file := app.files[app.scroll_y + i]

		app.tui.reset_bg_color()
		app.tui.reset_color()
		if i == app.cursor_y {
			app.tui.set_color(r: 255, g: 255, b: 255)
		}
		if app.processing_files[file] {
			app.tui.set_bg_color(r: 100)
		} else if app.processing_fbclips[file] {
			app.tui.set_bg_color(r: 100, g: 100)
		} else if app.new_fbclips[file] {
			app.tui.set_bg_color(g: 100)
		}
		app.tui.draw_text(1, i + 1, '${app.scroll_y + i:-4} ${file}')
		app.tui.reset_bg_color()
		app.tui.reset_color()
	}

	app.tui.set_cursor_position(1, app.cursor_y + 1)

	app.tui.flush()
}

fn draw_debug_info(x int, y int, mut app App) {
	lines := [
		'scroll_y:${app.scroll_y} cursor_y:${app.cursor_y} window_h:${app.tui.window_height} nfiles:${app.files.len}',
		'n files processing:${app.processing_files.keys().len}',
		'filter mode:${app.filter_mode}',
		'n_secs:${app.n_secs}',
	]
	for i, line in lines {
		app.tui.draw_text(x, y + i, line)
	}
}

fn draw_keyboard_shortcuts(x int, y int, mut app App) {
	lines := [
		'esc/q  quit',
		'j/down move cursor down',
		'k/up   move cursor up',
		'ctrl-d move cursor down 1 page',
		'ctrl-u move cursor up 1 page',
		'enter  play file in VLC from start (ctrl-q to quit VLC)',
		'space  play file in VLC from last ${app.n_secs} secs',
		'r      refresh file list',
		'o      open file in file explorer',
		'c      create a clip of the current file (last ${app.n_secs} secs)',
		'm      cycle through the filter modes',
		'1      set filter mode to all',
		'2      set filter mode to no_fbclips',
		'3      set filter mode to only_fbclips',
		'4      set filter mode to only_processing',
		'5      set filter mode to only_new_fbclips',
		'7      set n_secs = 25',
		'8      set n_secs = 20',
		'-      decrement n_secs by 1',
		'+      increment n_secs by 1',
	]
	for i, line in lines {
		app.tui.draw_text(x, y + i, line)
	}
}

fn is_fbclip(file string) bool {
	return file.ends_with(fbclip_ext)
}

fn exec(path string) string {
	mut out := ''
	mut line := ''
	mut cmd := os.Command{
		path: path
	}
	cmd.start() or { panic(err) }

	for {
		line = cmd.read_line()
		println(line)
		out += line
		if cmd.eof {
			return out
		}
	}

	return out
}

fn exec_in_new_process(command string, args []string, workdir string) {
	mut p := os.new_process(command)
	p.set_work_folder(workdir)
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	p.wait()
}

fn cleanup(mut app App) {
	unsafe {
		app.free()
	}
}

fn fail(error string) {
	eprintln(error)
}
