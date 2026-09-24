import os
import sys

from serena.config.serena_config import SerenaConfig
from serena.util.file_system import find_all_non_ignored_files
from solidlsp.ls_config import LanguageServerId

from serena_languages import select_languages

# Must run under Serena's own interpreter: it reuses Serena's file matchers,
# language priorities and gitignore handling so the chosen ids are exactly the
# ones `serena project create --language` accepts. These are Serena internals;
# the caller treats any failure here as "fall back to Serena's own inference".


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: serena_detect_languages.py <repo>\n")
        return 2
    config = SerenaConfig.from_config_file()
    priorities = {ls: config.get_ls_priority(ls) for ls in LanguageServerId}
    candidates = [ls for ls, priority in priorities.items() if priority > 0]
    matchers = {ls: ls.get_source_fn_matcher() for ls in candidates}

    file_matches = []
    for path in find_all_non_ignored_files(argv[1]):
        name = os.path.basename(path)
        file_matches.append(
            {ls.value for ls, m in matchers.items() if m.is_relevant_filename(name)}
        )

    by_value = {ls.value: priority for ls, priority in priorities.items()}
    for lang in select_languages(file_matches, by_value):
        print(lang)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
