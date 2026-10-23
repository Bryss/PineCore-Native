#pragma once

// Minimal argp for musl (OpenWrt), implemented on getopt_long.
//
// ArduLinux's main.cpp is the only user: a flat option table (--fsdir, --erase,
// --help, --usage, --version), ARGP_KEY_INIT/ARG, and argp_state_help(). Child
// parsers are accepted but not parsed; MeshCore never registers one.

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#include <vector>

#ifndef __error_t_defined
typedef int error_t;
#define __error_t_defined 1
#endif

#define ARGP_ERR_UNKNOWN E2BIG
#define ARGP_KEY_ARG 0
#define ARGP_KEY_END 0x1000001
#define ARGP_KEY_NO_ARGS 0x1000002
#define ARGP_KEY_INIT 0x1000003
#define ARGP_KEY_SUCCESS 0x1000004
#define ARGP_KEY_ERROR 0x1000005
#define ARGP_KEY_FINI 0x1000007

#define ARGP_NO_HELP 0x10
#define OPTION_ARG_OPTIONAL 0x1
#define OPTION_HIDDEN 0x2

#define ARGP_HELP_USAGE 0x01
#define ARGP_HELP_SHORT_USAGE 0x02
#define ARGP_HELP_SEE 0x04
#define ARGP_HELP_LONG 0x08
#define ARGP_HELP_PRE_DOC 0x10
#define ARGP_HELP_POST_DOC 0x20
#define ARGP_HELP_DOC (ARGP_HELP_PRE_DOC | ARGP_HELP_POST_DOC)
#define ARGP_HELP_BUG_ADDR 0x40
#define ARGP_HELP_LONG_ONLY 0x80
#define ARGP_HELP_EXIT_ERR 0x100
#define ARGP_HELP_EXIT_OK 0x200

struct argp_state;
typedef error_t (*argp_parser_t)(int key, char *arg, struct argp_state *state);

struct argp_option {
  const char *name;
  int key;
  const char *arg;
  int flags;
  const char *doc;
  int group;
};

struct argp;

struct argp_child {
  const struct argp *argp;
  int flags;
  const char *header;
  int group;
};

struct argp {
  const struct argp_option *options;
  argp_parser_t parser;
  const char *args_doc;
  const char *doc;
  const struct argp_child *children;
  char *(*help_filter)(int key, const char *text, void *input);
  const char *argp_domain;
};

struct argp_state {
  const struct argp *root_argp;
  int argc;
  char **argv;
  int next;
  unsigned flags;
  unsigned arg_num;
  int quoted;
  void *input;
  void **child_inputs;
  void *hook;
  char *name;
  FILE *err_stream;
  FILE *out_stream;
  void *pstate;
};

inline const char *argp_program_bug_address = nullptr;
inline const char *argp_program_version = nullptr;

inline void argp_state_help(const struct argp_state *state, FILE *stream, unsigned flags) {
  const struct argp *a = state ? state->root_argp : nullptr;
  const char *name = (state && state->name) ? state->name : "program";
  if (flags & (ARGP_HELP_USAGE | ARGP_HELP_SHORT_USAGE)) {
    fprintf(stream, "Usage: %s [OPTION...] %s\n", name, (a && a->args_doc) ? a->args_doc : "");
  }
  if ((flags & ARGP_HELP_LONG) && a && a->options) {
    for (const struct argp_option *o = a->options; o->name || o->key || o->doc; o++) {
      if (!o->name || (o->flags & OPTION_HIDDEN)) continue;
      std::string spec = "      --" + std::string(o->name);
      if (o->key > 0 && o->key < 128 && o->key != '?') spec = "  -" + std::string(1, (char)o->key) + ", --" + o->name;
      if (o->arg) spec += "=" + std::string(o->arg);
      fprintf(stream, "%-28s %s\n", spec.c_str(), o->doc ? o->doc : "");
    }
  }
  if ((flags & ARGP_HELP_BUG_ADDR) && argp_program_bug_address) {
    fprintf(stream, "\nReport bugs to %s.\n", argp_program_bug_address);
  }
  if (flags & ARGP_HELP_EXIT_OK) exit(0);
  if (flags & ARGP_HELP_EXIT_ERR) exit(64);
}

inline error_t argp_parse(const struct argp *argp, int argc, char **argv, unsigned flags,
                          int *arg_index, void *input) {
  void *child_inputs[4] = {nullptr, nullptr, nullptr, nullptr};
  struct argp_state state;
  memset(&state, 0, sizeof(state));
  state.root_argp = argp;
  state.argc = argc;
  state.argv = argv;
  state.flags = flags;
  state.input = input;
  state.child_inputs = child_inputs;
  state.name = argv[0];
  state.err_stream = stderr;
  state.out_stream = stdout;

  // Long options map to 256 + index so a key of '?' (--help) can't be confused
  // with getopt's own '?' error return.
  std::vector<struct option> longopts;
  std::vector<int> keys;
  std::string shortopts = ":";
  for (const struct argp_option *o = argp->options; o && (o->name || o->key || o->doc); o++) {
    if (o->name) {
      int has_arg = o->arg ? ((o->flags & OPTION_ARG_OPTIONAL) ? optional_argument : required_argument)
                           : no_argument;
      longopts.push_back({o->name, has_arg, nullptr, 256 + (int)keys.size()});
      keys.push_back(o->key);
    }
    if (o->key > 0 && o->key < 128 && o->key != '?' && o->key != ':') {
      shortopts += (char)o->key;
      if (o->arg) shortopts += (o->flags & OPTION_ARG_OPTIONAL) ? "::" : ":";
    }
  }
  longopts.push_back({nullptr, 0, nullptr, 0});

  argp->parser(ARGP_KEY_INIT, nullptr, &state);
  optind = 1;
  int c;
  while ((c = getopt_long(argc, argv, shortopts.c_str(), longopts.data(), nullptr)) != -1) {
    if (c == '?' || c == ':') {
      fprintf(stderr, "%s: %s option '%s'\n", argv[0], c == ':' ? "missing argument for" : "unrecognized",
              argv[optind - 1]);
      return EINVAL;
    }
    int key = c >= 256 ? keys[(size_t)(c - 256)] : c;
    error_t err = argp->parser(key, optarg, &state);
    if (err && err != ARGP_ERR_UNKNOWN) return err;
  }
  for (state.next = optind; state.next < argc; state.next++) {
    error_t err = argp->parser(ARGP_KEY_ARG, argv[state.next], &state);
    state.arg_num++;
    if (err && err != ARGP_ERR_UNKNOWN) return err;
  }
  argp->parser(ARGP_KEY_END, nullptr, &state);
  argp->parser(ARGP_KEY_SUCCESS, nullptr, &state);
  argp->parser(ARGP_KEY_FINI, nullptr, &state);
  if (arg_index) *arg_index = argc;
  return 0;
}
