/* vh-sched spike S1: the numbers bpf_uapi.zig asserts against, from the 6.18.57 uapi headers */
#include <stdio.h>
#include <stddef.h>
#include <linux/bpf.h>
#include <linux/btf.h>
#define P(x) printf("%-48s %lu\n", #x, (unsigned long)(x))
int main(void) {
    P(sizeof(union bpf_attr));
    P(sizeof(struct bpf_insn));
    P(sizeof(struct bpf_prog_info));
    P(sizeof(struct bpf_map_info));
    P(sizeof(struct bpf_link_info));
    P(sizeof(struct bpf_btf_info));
    P(offsetof(struct bpf_link_info, struct_ops));
    P(offsetof(struct bpf_link_info, struct_ops.map_id));
    P(offsetof(struct bpf_map_info, id));
    P(offsetof(struct bpf_prog_info, id));
    P(offsetof(struct bpf_btf_info, id));
    P(offsetof(union bpf_attr, map_type));
    P(offsetof(union bpf_attr, btf_vmlinux_value_type_id));
    P(offsetof(union bpf_attr, map_extra));
    P(offsetof(union bpf_attr, value_type_btf_obj_fd));
    P(offsetof(union bpf_attr, map_token_fd));
    P(offsetof(union bpf_attr, excl_prog_hash));
    P(offsetof(union bpf_attr, excl_prog_hash_size));
    P(offsetof(union bpf_attr, map_fd));
    P(offsetof(union bpf_attr, key));
    P(offsetof(union bpf_attr, value));
    P(offsetof(union bpf_attr, flags));
    P(offsetof(union bpf_attr, prog_type));
    P(offsetof(union bpf_attr, insns));
    P(offsetof(union bpf_attr, license));
    P(offsetof(union bpf_attr, log_buf));
    P(offsetof(union bpf_attr, prog_name));
    P(offsetof(union bpf_attr, expected_attach_type));
    P(offsetof(union bpf_attr, prog_btf_fd));
    P(offsetof(union bpf_attr, attach_btf_id));
    P(offsetof(union bpf_attr, attach_btf_obj_fd));
    P(offsetof(union bpf_attr, fd_array));
    P(offsetof(union bpf_attr, log_true_size));
    P(offsetof(union bpf_attr, prog_token_fd));
    P(offsetof(union bpf_attr, fd_array_cnt));
    P(offsetof(union bpf_attr, signature));
    P(offsetof(union bpf_attr, keyring_id));
    P(offsetof(union bpf_attr, btf));
    P(offsetof(union bpf_attr, btf_log_buf));
    P(offsetof(union bpf_attr, btf_size));
    P(offsetof(union bpf_attr, btf_log_true_size));
    P(offsetof(union bpf_attr, btf_flags));
    P(offsetof(union bpf_attr, btf_token_fd));
    P(offsetof(union bpf_attr, info));
    P(offsetof(union bpf_attr, info.bpf_fd));
    P(offsetof(union bpf_attr, info.info_len));
    P(offsetof(union bpf_attr, info.info));
    P(offsetof(union bpf_attr, link_create));
    P(offsetof(union bpf_attr, link_create.map_fd));
    P(offsetof(union bpf_attr, link_create.target_fd));
    P(offsetof(union bpf_attr, link_create.attach_type));
    P(offsetof(union bpf_attr, link_create.flags));
    P(offsetof(union bpf_attr, link_create.target_btf_id));
    P(offsetof(union bpf_attr, link_detach));
    P(offsetof(union bpf_attr, link_detach.link_fd));
    P(BPF_MAP_CREATE); P(BPF_MAP_LOOKUP_ELEM); P(BPF_MAP_UPDATE_ELEM); P(BPF_PROG_LOAD);
    P(BPF_OBJ_GET_INFO_BY_FD); P(BPF_BTF_LOAD); P(BPF_MAP_FREEZE); P(BPF_LINK_CREATE);
    P(BPF_LINK_DETACH); P(BPF_LINK_UPDATE);
    P(BPF_MAP_TYPE_ARRAY); P(BPF_MAP_TYPE_STRUCT_OPS); P(BPF_MAP_TYPE_RINGBUF);
    P(BPF_PROG_TYPE_STRUCT_OPS);
    P(BPF_STRUCT_OPS); P(BPF_TRACE_FENTRY);
    P(BPF_LINK_TYPE_STRUCT_OPS);
    P(BPF_F_LINK); P(BPF_F_SLEEPABLE); P(BPF_F_RDONLY_PROG); P(BPF_F_MMAPABLE);
    P(BPF_F_VTYPE_BTF_OBJ_FD); P(BPF_F_TOKEN_FD);
    P(BPF_PSEUDO_MAP_FD); P(BPF_PSEUDO_MAP_VALUE); P(BPF_PSEUDO_CALL); P(BPF_PSEUDO_KFUNC_CALL);
    P(BPF_PSEUDO_FUNC);
    P(BPF_OBJ_NAME_LEN);
    P(BPF_FUNC_ringbuf_output); P(BPF_FUNC_ringbuf_reserve); P(BPF_FUNC_ringbuf_submit);
    P(BPF_FUNC_ktime_get_ns); P(BPF_FUNC_get_smp_processor_id); P(BPF_FUNC_map_lookup_elem);
    P(BPF_FUNC_probe_read_kernel); P(BPF_FUNC_trace_printk);
    P(BPF_RINGBUF_BUSY_BIT); P(BPF_RINGBUF_DISCARD_BIT); P(BPF_RINGBUF_HDR_SZ);
    P(BTF_MAGIC); P(BTF_VERSION); P(sizeof(struct btf_header)); P(sizeof(struct btf_type));
    P(BTF_KIND_INT); P(BTF_KIND_PTR); P(BTF_KIND_ARRAY); P(BTF_KIND_STRUCT); P(BTF_KIND_UNION);
    P(BTF_KIND_ENUM); P(BTF_KIND_FWD); P(BTF_KIND_TYPEDEF); P(BTF_KIND_VOLATILE); P(BTF_KIND_CONST);
    P(BTF_KIND_RESTRICT); P(BTF_KIND_FUNC); P(BTF_KIND_FUNC_PROTO); P(BTF_KIND_VAR); P(BTF_KIND_DATASEC);
    P(BTF_KIND_FLOAT); P(BTF_KIND_DECL_TAG); P(BTF_KIND_TYPE_TAG); P(BTF_KIND_ENUM64);
    P(BTF_INT_SIGNED); P(BTF_INT_CHAR); P(BTF_INT_BOOL);
    P(BTF_VAR_STATIC); P(BTF_VAR_GLOBAL_ALLOCATED);
    P(BTF_FUNC_STATIC); P(BTF_FUNC_GLOBAL);
    return 0;
}
