# cython: infer_types=True, profile=True
from typing import List
from collections import defaultdict
from functools import lru_cache
from itertools import product

import numpy

from .matcher cimport Matcher
from ..vocab cimport Vocab
from ..tokens.doc cimport Doc

from ..errors import Errors
from ..tokens import Span


DELIMITER = "||"
INDEX_HEAD = 1
INDEX_RELOP = 0


cdef class DependencyMatcher:
    """Match dependency parse tree based on pattern rules."""
    cdef readonly Vocab vocab
    cdef readonly Matcher _matcher
    cdef public object _patterns
    cdef public object _raw_patterns
    cdef public object _tokens_to_key
    cdef public object _root
    cdef public object _callbacks
    cdef public object _tree
    cdef public object _ops

    def __init__(self, vocab, *, validate=False):
        """Create the DependencyMatcher.

        vocab (Vocab): The vocabulary object, which must be shared with the
            documents the matcher will operate on.
        validate (bool): Whether patterns should be validated, passed to
            Matcher as `validate`
        """
        self._matcher = Matcher(vocab, validate=validate)

        # Associates each key to the raw patterns list added by the user
        # e.g. {'key': [[{'RIGHT_ID': ..., 'RIGHT_ATTRS': ... }, ... ], ... ], ... }
        self._raw_patterns = defaultdict(list)

        # Associates each key to a list of lists of 'RIGHT_ATTRS'
        # e.g. {'key': [[{'POS': ... }, ... ], ... ], ... }
        self._patterns = defaultdict(list)

        # Associates each key to a list of lists where each list associates
        # a token position within the pattern to the key used by the internal matcher) 
        # e.g. {'key': [ ['token_key', ... ], ... ], ... }
        self._tokens_to_key = defaultdict(list)

        # Associates each key to a list of ints where each int corresponds
        # to the position of the root token within the pattern
        # e.g. {'key': [3, 1, 4, ... ], ... }
        self._root = defaultdict(list)

        # Associates each key to a list of dicts where each dict describes all
        # branches from a token (identifed by its position) to other tokens as
        # a list of tuples: ('REL_OP', 'LEFT_ID')
        # e.g. {'key': [{2: [('<', 'left_id'), ...] ...}, ... ], ...}
        self._tree = defaultdict(list)

        # Associates each key to its on_match callback
        # e.g. {'key': on_match_callback, ...}
        self._callbacks = {}

        self.vocab = vocab
        self._ops = {
            "<": self._dep,
            ">": self._gov,
            "<<": self._dep_chain,
            ">>": self._gov_chain,
            ".": self._imm_precede,
            ".*": self._precede,
            ";": self._imm_follow,
            ";*": self._follow,
            "$+": self._imm_right_sib,
            "$-": self._imm_left_sib,
            "$++": self._right_sib,
            "$--": self._left_sib,
        }

    def __reduce__(self):
        data = (self.vocab, self._raw_patterns, self._callbacks)
        return (unpickle_matcher, data, None, None)

    def __len__(self):
        """Get the number of rules, which are edges, added to the dependency
        tree matcher.

        RETURNS (int): The number of rules.
        """
        return len(self._patterns)

    def __contains__(self, key):
        """Check whether the matcher contains rules for a match ID.

        key (str): The match ID.
        RETURNS (bool): Whether the matcher contains rules for this match ID.
        """
        return self.has_key(key)

    def _validate_input(self, pattern, key):
        idx = 0
        visited_nodes = {}
        for relation in pattern:
            if not isinstance(relation, dict):
                raise ValueError(Errors.E1008)
            if "RIGHT_ATTRS" not in relation and "RIGHT_ID" not in relation:
                raise ValueError(Errors.E098.format(key=key))
            if idx == 0:
                if not(
                    "RIGHT_ID" in relation
                    and "REL_OP" not in relation
                    and "LEFT_ID" not in relation
                ):
                    raise ValueError(Errors.E099.format(key=key))
                visited_nodes[relation["RIGHT_ID"]] = True
            else:
                if not(
                    "RIGHT_ID" in relation
                    and "RIGHT_ATTRS" in relation
                    and "REL_OP" in relation
                    and "LEFT_ID" in relation
                ):
                    raise ValueError(Errors.E100.format(key=key))
                if (
                    relation["RIGHT_ID"] in visited_nodes
                    or relation["LEFT_ID"] not in visited_nodes
                ):
                    raise ValueError(Errors.E101.format(key=key))
                if relation["REL_OP"] not in self._ops:
                    raise ValueError(Errors.E1007.format(op=relation["REL_OP"]))
                visited_nodes[relation["RIGHT_ID"]] = True
                visited_nodes[relation["LEFT_ID"]] = True
            idx = idx + 1

    def _get_matcher_key(self, key, pattern_idx, token_idx):
        """
        Creates a token key to be used by the matcher
        """
        return self._normalize_key(
            unicode(key) + DELIMITER + 
            unicode(pattern_idx) + DELIMITER + 
            unicode(token_idx)
        )

    def add(self, key, patterns, *, on_match=None):
        """Add a new matcher rule to the matcher.

        key (str): The match ID.
        patterns (list): The patterns to add for the given key.
        on_match (callable): Optional callback executed on match.
        """
        if on_match is not None and not hasattr(on_match, "__call__"):
            raise ValueError(Errors.E171.format(arg_type=type(on_match)))
        if patterns is None or not isinstance(patterns, List):  # old API
            raise ValueError(Errors.E948.format(arg_type=type(patterns)))
        for pattern in patterns:
            if len(pattern) == 0:
                raise ValueError(Errors.E012.format(key=key))
            self._validate_input(pattern, key)

        key = self._normalize_key(key)

        # Save raw patterns and on_match callback
        self._raw_patterns[key].extend(patterns)
        self._callbacks[key] = on_match

        # Add 'RIGHT_ATTRS' to self._patterns[key]
        _patterns = []
        for pattern in patterns:
            token_patterns = []
            for i in range(len(pattern)):
                token_pattern = [pattern[i]["RIGHT_ATTRS"]]
                token_patterns.append(token_pattern)
            _patterns.append(token_patterns)
        self._patterns[key].extend(_patterns)

        # Add each node pattern of all the input patterns individually to the
        # matcher. This enables only a single instance of Matcher to be used.
        # Multiple adds are required to track each node pattern.
        tokens_to_key_list = []
        for i in range(len(_patterns)):

            # Preallocate list space
            tokens_to_key = [None]*len(_patterns[i])

            # TODO: Better ways to hash edges in pattern?
            for j in range(len(_patterns[i])):
                k = self._get_matcher_key(key, i, j)
                self._matcher.add(k, [_patterns[i][j]])
                tokens_to_key[j] = k

            tokens_to_key_list.append(tokens_to_key)

        self._tokens_to_key[key].extend(tokens_to_key_list)

        # Create an object tree to traverse later on. This data structure
        # enables easy tree pattern match. Doc-Token based tree cannot be
        # reused since it is memory-heavy and tightly coupled with the Doc.
        self._retrieve_tree(patterns, key)

    def _retrieve_tree(self, patterns, key):

        # New trees belonging to this key
        tree_list = []

        # List of indices to the root nodes
        root_list = []

        # Group token id to create trees 
        for i, pattern in enumerate(patterns):
            tree = defaultdict(list)
            root = -1

            right_id_to_token = {}
            for j, token in enumerate(pattern):
                right_id_to_token[token["RIGHT_ID"]] = j

            for j, token in enumerate(pattern):
                if "REL_OP" in token:
                    # Add tree branch
                    tree[right_id_to_token[token["LEFT_ID"]]].append(
                        (token["REL_OP"], j),
                    )
                else:
                    # No 'REL_OP', this is the root
                    root = j

            tree_list.append(tree)
            root_list.append(root)

        self._tree[key].extend(tree_list)
        self._root[key].extend(root_list)

    def has_key(self, key):
        """Check whether the matcher has a rule with a given key.

        key (string or int): The key to check.
        RETURNS (bool): Whether the matcher has the rule.
        """
        return self._normalize_key(key) in self._patterns

    def get(self, key, default=None):
        """Retrieve the pattern stored for a key.

        key (str / int): The key to retrieve.
        RETURNS (tuple): The rule, as an (on_match, patterns) tuple.
        """
        key = self._normalize_key(key)
        if key not in self._raw_patterns:
            return default
        return (self._callbacks[key], self._raw_patterns[key])

    def remove(self, key):
        key = self._normalize_key(key)
        if not key in self._patterns:
            raise ValueError(Errors.E175.format(key=key))
        self._patterns.pop(key)
        self._raw_patterns.pop(key)
        self._tree.pop(key)
        self._root.pop(key)
        self._tokens_to_key.pop(key)

    def _get_keys_to_position_maps(self, doc):
        """
        Processes the doc and groups all matches by their root and match id.
        Returns a dict mapping each (root, match id) pair to the list of
        tokens indices which are descendants of root and match the token
        pattern identified by the given match id.

        e.g. keys_to_position_maps[root_index][match_id] = [...]
        """
        keys_to_position_maps = defaultdict(lambda: defaultdict(list))
        for match_id, start, _ in self._matcher(doc):
            start = doc[start]
            root = ([start] + list(start.ancestors))[-1]
            keys_to_position_maps[root.i][match_id].append(start)
        return keys_to_position_maps

    def __call__(self, object doclike):
        """Find all token sequences matching the supplied pattern.

        doclike (Doc or Span): The document to match over.
        RETURNS (list): A list of `(key, start, end)` tuples,
            describing the matches. A match tuple describes a span
            `doc[start:end]`. The `label_id` and `key` are both integers.
        """
        if isinstance(doclike, Doc):
            doc = doclike
        elif isinstance(doclike, Span):
            doc = doclike.as_doc()
        else:
            raise ValueError(Errors.E195.format(good="Doc or Span", got=type(doclike).__name__))

        matched_key_trees = []
        keys_to_position_maps = self._get_keys_to_position_maps(doc)

        for key in self._patterns.keys():
            for root, tree, tokens_to_key in zip(
                self._root[key],
                self._tree[key],
                self._tokens_to_key[key],
            ):
                for keys_to_position in keys_to_position_maps.values():
                    for matched_tree in self._get_matches(doc, tree, tokens_to_key, keys_to_position):
                        matched_key_trees.append((key, matched_tree))

        for i, (match_id, nodes) in enumerate(matched_key_trees):
            on_match = self._callbacks.get(match_id)
            if on_match is not None:
                on_match(self, doc, i, matched_key_trees)

        # Clear cache, this is needed to avoid a too-large memory footprint if the same
        # DependencyMatcher instance is used to process multiple documents
        self._resolve_node_operator.cache_clear()

        return matched_key_trees

    def _get_matches(self, doc, tree, tokens_to_key, keys_to_position):
        cdef bint is_valid

        all_positions = [keys_to_position[key] for key in tokens_to_key]

        # Generate all potential matches by computing the cartesian product of all
        # position of the matched tokens
        for candidate_match in product(*all_positions):

            # A potential match is a valid match if all relationhips between the
            # matched tokens are satisfied.
            is_valid = True
            for left_idx in range(len(candidate_match)):
                is_valid = self._check_relationships(doc, candidate_match, left_idx, tree)

                if not is_valid:
                    break

            if is_valid:
                yield list(candidate_match)

    def _check_relationships(self, doc, candidate_match, left_idx, tree):
        # Position of the left operand within the document
        left_pos = candidate_match[left_idx]

        for relop, right_idx in tree[left_idx]:

            # Position of the left operand within the document
            right_pos = candidate_match[right_idx]

            # List of valid right matches
            valid_right_matches = self._resolve_node_operator(doc, left_pos, relop)

            # If the proposed right token is not within the valid ones, fail
            if right_pos not in valid_right_matches:
                return False

        return True


    @lru_cache(maxsize=None)
    def _resolve_node_operator(self, doc, node, operator):
        """
        Given a doc, a node (as a index in the doc) and a REL_OP operator
        returns the list of nodes from the doc that belong to node+operator. 

        The result is memoized using an unbounded cache, therefore the cache
        must be cleared after finishing processing a doc:
            self._resolve_node_operator.cache_clear()
        """
        return [token.i for token in self._ops[operator](doc, node)]

    def _dep(self, doc, node):
        if doc[node].head == doc[node]:
            return []
        return [doc[node].head]

    def _gov(self,doc,node):
        return list(doc[node].children)

    def _dep_chain(self, doc, node):
        return list(doc[node].ancestors)

    def _gov_chain(self, doc, node):
        return [t for t in doc[node].subtree if t != doc[node]]

    def _imm_precede(self, doc, node):
        sent = self._get_sent(doc[node])
        if node < len(doc) - 1 and doc[node + 1] in sent:
            return [doc[node + 1]]
        return []

    def _precede(self, doc, node):
        sent = self._get_sent(doc[node])
        return [doc[i] for i in range(node + 1, sent.end)]

    def _imm_follow(self, doc, node):
        sent = self._get_sent(doc[node])
        if node > 0 and doc[node - 1] in sent:
            return [doc[node - 1]]
        return []

    def _follow(self, doc, node):
        sent = self._get_sent(doc[node])
        return [doc[i] for i in range(sent.start, node)]

    def _imm_right_sib(self, doc, node):
        for child in list(doc[node].head.children):
            if child.i == node + 1:
                return [doc[child.i]]
        return []

    def _imm_left_sib(self, doc, node):
        for child in list(doc[node].head.children):
            if child.i == node - 1:
                return [doc[child.i]]
        return []

    def _right_sib(self, doc, node):
        candidate_children = []
        for child in list(doc[node].head.children):
            if child.i > node:
                candidate_children.append(doc[child.i])
        return candidate_children

    def _left_sib(self, doc, node):
        candidate_children = []
        for child in list(doc[node].head.children):
            if child.i < node:
                candidate_children.append(doc[child.i])
        return candidate_children

    def _normalize_key(self, key):
        if isinstance(key, basestring):
            return self.vocab.strings.add(key)
        else:
            return key

    def _get_sent(self, token):
        root = (list(token.ancestors) or [token])[-1]
        return token.doc[root.left_edge.i:root.right_edge.i + 1]


def unpickle_matcher(vocab, patterns, callbacks):
    matcher = DependencyMatcher(vocab)
    for key, pattern in patterns.items():
        callback = callbacks.get(key, None)
        matcher.add(key, pattern, on_match=callback)
    return matcher
