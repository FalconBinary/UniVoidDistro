# vim: set ts=4 sw=4 et:
# void-hardperf-light: transparent huge pages (THP) in madvise mode (the Void kernel default):
# only programs that ask get them (Firefox, mesa). defer+madvise: memory compaction for
# them happens in the background (kcompactd), not at allocation time, so there are no
# page-fault stalls. Same as CachyOS (docs/11, docs/15).
[ -w /sys/kernel/mm/transparent_hugepage/defrag ] && \
    echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag
