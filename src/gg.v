module main

import math
import os
import gg
import gx

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
	gg                &gg.Context = unsafe { nil }
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
	app.gg = gg.new_context(
		bg_color: gx.light_gray
		width: 900
		height: 1200
		user_data: app
		create_window: true
		event_fn: event
		frame_fn: frame
	)
	app.gg.run()
}

fn event(e &gg.Event, mut app App) {
	if e.typ != .key_down {
		return
	}

	if app.gg.key_modifiers == .ctrl {
		handle_ctrl_key(e, mut app)
	} else if !(app.gg.key_modifiers.all(.ctrl | .shift | .alt)) { // no modifiers
		handle_normal_key(e, mut app)
	}
}

fn handle_ctrl_key(e &gg.Event, mut app App) {
	_, n_rows := get_screen_text_info(app.gg)
	match e.key_code {
		.u { // scroll up a screen
			move_cursor_up(n_rows, mut app)
		}
		.d { // scroll down a screen
			move_cursor_down(n_rows, mut app)
		}
		else {}
	}
}

fn handle_normal_key(e &gg.Event, mut app App) {
	match e.key_code {
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
		.kp_add, .equal {
			app.n_secs++
		}
		else {}
	}
}

fn move_cursor_down(delta int, mut app App) {
	_, n_rows := get_screen_text_info(app.gg)
	app.cursor_y += delta
	if app.files.len < n_rows { // fewer files than vertical lines
		app.scroll_y = 0
		app.cursor_y = math.min(app.files.len - 1, app.cursor_y)
	} else { // more files than vertical lines
		if app.cursor_y >= n_rows {
			app.cursor_y = n_rows - 1
			app.scroll_y = math.min(app.files.len - n_rows, app.scroll_y + delta)
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
	_, n_rows := get_screen_text_info(app.gg)
	if app.files.len < n_rows {
		app.cursor_y = math.max(0, math.min(app.files.len - 1, app.cursor_y))
		app.scroll_y = 0
	} else {
		app.cursor_y = math.max(0, math.min(n_rows - 1, app.cursor_y))
		app.scroll_y = math.min(app.files.len - n_rows, app.scroll_y)
	}
}

fn draw(mut app App) {
	app.gg.begin()

	text_height, n_rows := get_screen_text_info(app.gg)
	h := math.min(n_rows, app.files.len)
	wsize := app.gg.window_size()

	draw_debug_info(wsize.width/2, 0, mut app)
	draw_keyboard_shortcuts(wsize.width/2, 7, mut app)

	draw_cursor(mut app, text_height)

	// draw files
	for i := 0; i < h; i++ {
		file := app.files[app.scroll_y + i]
		text := get_file_line_text(app.scroll_y, i, file)

		mut col := gx.black
		if app.processing_files[file] {
			col = gx.red
		} else if app.processing_fbclips[file] {
			col = gx.yellow
		} else if app.new_fbclips[file] {
			col = gx.rgb(0, 150, 0)
		}
		app.gg.draw_text(1, i*text_height, text, gx.TextCfg{
			color: col
		})
	}

	app.gg.end()
}

fn draw_cursor(mut app App, text_height int) {
	i := app.scroll_y + app.cursor_y
	if i >= app.files.len {
		return
	}
	file := app.files[i]
	text := get_file_line_text(app.scroll_y, app.cursor_y, file)
	w := app.gg.text_width(text)
	app.gg.draw_rect_filled(1.0, f32(app.cursor_y*text_height), f32(w), f32(text_height), gx.dark_gray)
}

fn get_file_line_text(scroll_y int, i int, file string) string {
 	return '${scroll_y + i:-4} ${file}'
}

fn draw_debug_info(x_pixels int, y_row int, mut app App) {
	text_height, n_rows := get_screen_text_info(app.gg)
	lines := [
		'scroll_y:${app.scroll_y} cursor_y:${app.cursor_y} window_h(rows):${n_rows} nfiles:${app.files.len}',
		'n files processing:${app.processing_files.keys().len}',
		'filter mode:${app.filter_mode}',
		'n_secs:${app.n_secs}',
	]
	for i, line in lines {
		app.gg.draw_text(x_pixels, (y_row + i)*text_height, line)
	}
}

// returns text_height and n_rows (Vertical rows)
fn get_screen_text_info(ctx gg.Context) (int, int) {
	text_height := ctx.text_height('hello')
	window_height := ctx.window_size().height
	return text_height, window_height/text_height
}

fn draw_keyboard_shortcuts(x_pixels int, y_row int, mut app App) {
	text_height := app.gg.text_height('hello')
	lines := [
		'esc/q  quit',
		'j/down move cursor down',
		'k/up   move cursor up',
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
		app.gg.draw_text(x_pixels, (y_row + i)*text_height, line)
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
