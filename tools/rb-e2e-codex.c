// A process named codex for tools/rb-e2e.sh. The system stops a copy of /bin/zsh at launch,
// so this program keeps the shell as its child and stays in the caller's process chain.
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    pid_t child = fork();
    if (child == 0) {
        char *shell[] = {"zsh", argc > 1 ? argv[1] : 0, argc > 2 ? argv[2] : 0, 0};
        execv("/bin/zsh", shell);
        _exit(127);
    }
    int status = 1;
    waitpid(child, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
