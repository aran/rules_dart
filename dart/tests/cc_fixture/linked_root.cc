int linked_dep();
int exported();
int linked_root() { return linked_dep() + exported(); }
