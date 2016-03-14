#!/usr/bin/env python

import sys
import logging
import codecs

import argparse
from IPython.utils.io import stdout

def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('--expect-uttid', type=bool, default=False)
    parser.add_argument('--split-sil', default=None)
    parser.add_argument('rules_dir')
    parser.add_argument('text_file', default='-', nargs='?')
    parser.add_argument('phoneme_file', default='-', nargs='?')
    return parser


if __name__=='__main__':
    logging.basicConfig(level=logging.INFO)
    parser = get_parser()
    args = parser.parse_args()
    
    if args.text_file == '-':
        args.text_file = codecs.getreader('utf-8')(sys.stdin)
    else:
        args.text_file = codecs.open(args.text_file, 'r', 'utf-8')
        
    if args.phoneme_file == '-':
        args.phoneme_file = codecs.getwriter('utf-8')(sys.stdout)
    else:
        args.phoneme_file = codecs.open(args.phoneme_file, 'w', 'utf-8')
    
    logging.info("Appending %s to path", args.rules_dir)
    sys.path.append(args.rules_dir)
    from pronounce import PronRules, saySentence
    rules = PronRules(args.rules_dir)
    
    for line in args.text_file:
        line = line.strip()
        if line=="":
            continue
        uttid=u""
        if args.expect_uttid:
            uttid, line = line.split(None,1)
            uttid = "%s " % (uttid, )
        if not args.split_sil:
            phones = u" ".join(saySentence(line, rules))
        else:
            segments = line.split(args.split_sil)
            segment_phones = [" ".join(saySentence(s.strip(), rules)) for s in segments]
            phones = (" %s " % (args.split_sil, )).join(segment_phones)
        #logging.debug("phones: %s", phones)
        args.phoneme_file.write("%s%s\n" % (uttid, phones),)