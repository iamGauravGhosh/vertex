"""ncurses insert/edit/resize fixture using the distribution Python binding."""
import curses


def main(screen):
    curses.curs_set(1)
    screen.keypad(True)
    curses.start_color()
    curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)
    marker = "VERTEX_FRAMEWORK_READY"
    while True:
        screen.erase()
        screen.addstr(0, 0, marker, curses.color_pair(1) | curses.A_UNDERLINE)
        screen.addstr(1, 0, "界 é borders: ┌─┐")
        screen.refresh()
        key = screen.get_wch()
        if key in ("q", "\x03"):
            return
        if key != curses.KEY_RESIZE:
            marker = "VERTEX_FRAMEWORK_INPUT " + str(key)


curses.wrapper(main)
