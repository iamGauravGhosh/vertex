package main

import tea "github.com/charmbracelet/bubbletea"

type model struct{ text string }

func (m model) Init() tea.Cmd { return nil }
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch key := msg.(type) {
	case tea.KeyMsg:
		if key.String() == "q" || key.String() == "ctrl+c" {
			return m, tea.Quit
		}
		m.text = "VERTEX_FRAMEWORK_INPUT " + key.String()
	}
	return m, nil
}
func (m model) View() string {
	return "\x1b[38;2;85;153;255m" + m.text + "\x1b[0m\r\n界 é 👩‍💻\r\n"
}
func main() {
	if _, err := tea.NewProgram(model{"VERTEX_FRAMEWORK_READY"}, tea.WithAltScreen()).Run(); err != nil {
		panic(err)
	}
}
