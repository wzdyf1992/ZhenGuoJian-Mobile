import os
from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = True

    @property
    def slug(self) -> str:
        return 'zhenguojian'

    @property
    def bundle_identifier(self) -> str:
        return 'com.guoapp.all'

    @property
    def flutter_arguments(self) -> list[str]:
        return ['--dart-define=ALL_SOURCES=true']

    @property
    def linker_flags(self) -> str:
        flags = '-s -w -X duanjuapp/native/core.buildAllSources=true'
        update_server = os.environ.get('UPDATE_SERVER_URL', '').strip()
        if update_server:
            flags += ' -X duanjuapp/native/core.nativeUpdateServer=' + update_server
        return flags
