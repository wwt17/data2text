from __future__ import print_function
from __future__ import division
from __future__ import absolute_import

import sys
import argparse
from pyxdameraulevenshtein import normalized_damerau_levenshtein_distance

full_names = ['Atlanta Hawks', 'Boston Celtics', 'Brooklyn Nets', 'Charlotte Hornets',
 'Chicago Bulls', 'Cleveland Cavaliers', 'Detroit Pistons', 'Indiana Pacers',
 'Miami Heat', 'Milwaukee Bucks', 'New York Knicks', 'Orlando Magic',
 'Philadelphia 76ers', 'Toronto Raptors', 'Washington Wizards', 'Dallas Mavericks',
 'Denver Nuggets', 'Golden State Warriors', 'Houston Rockets', 'Los Angeles Clippers',
 'Los Angeles Lakers', 'Memphis Grizzlies', 'Minnesota Timberwolves', 'New Orleans Pelicans',
 'Oklahoma City Thunder', 'Phoenix Suns', 'Portland Trail Blazers', 'Sacramento Kings',
 'San Antonio Spurs', 'Utah Jazz']

cities, teams = set(), set()
ec = {} # equivalence classes
for team in full_names:
    pieces = team.split()
    if len(pieces) == 2:
        ec[team] = [pieces[0], pieces[1]]
        cities.add(pieces[0])
        teams.add(pieces[1])
    elif pieces[0] == "Portland": # only 2-word team
        ec[team] = [pieces[0], " ".join(pieces[1:])]
        cities.add(pieces[0])
        teams.add(" ".join(pieces[1:]))
    else: # must be a 2-word City
        ec[team] = [" ".join(pieces[:2]), pieces[2]]
        cities.add(" ".join(pieces[:2]))
        teams.add(pieces[2])


def same_ent(e1, e2):
    if e1 in cities or e1 in teams:
        return e1 == e2 or any((e1 in fullname and e2 in fullname for fullname in full_names))
    else:
        return e1 in e2 or e2 in e1

def trip_match(t1, t2):
    return t1[1] == t2[1] and t1[2] == t2[2] and same_ent(t1[0], t2[0])

def dedup_triples(triplist):
    """
    this will be inefficient but who cares
    """
    ret = []
    for i, t_i in enumerate(triplist):
        for j in xrange(i):
            t_j = triplist[j]
            if trip_match(t_i, t_j):
                break
        else:
            ret.append(t_i)
    return ret

def get_triples(fi):
    with open(fi) as f:
        return list(map(
            lambda line: dedup_triples(list(map(
                lambda s: tuple(s.split('|')),
                line.strip().split()))),
            f))

def calc_precrec(gold_triples, pred_triples):
    total_tp, total_predicted, total_gold = 0, 0, 0
    for i, triplist in enumerate(pred_triples):
        tp = sum((1 for j in xrange(len(triplist))
                    if any(trip_match(triplist[j], gold_triples[i][k])
                           for k in xrange(len(gold_triples[i])))))
        total_tp += tp
        total_predicted += len(triplist)
        total_gold += len(gold_triples[i])
    avg_prec = total_tp / total_predicted
    avg_rec = total_tp / total_gold
    print("totals:", total_tp, total_predicted, total_gold)
    print("prec:", avg_prec, "rec:", avg_rec)
    return avg_prec, avg_rec

def norm_dld(l1, l2):
    ascii_start = 0
    # make a string for l1
    # all triples are unique...
    s1 = ''.join((chr(ascii_start+i) for i in xrange(len(l1))))
    s2 = ''
    next_char = ascii_start + len(s1)
    for j in xrange(len(l2)):
        found = None
        #next_char = chr(ascii_start+len(s1)+j)
        for k in xrange(len(l1)):
            if trip_match(l2[j], l1[k]):
                found = s1[k]
                #next_char = s1[k]
                break
        if found is None:
            s2 += chr(next_char)
            next_char += 1
            assert next_char <= 128
        else:
            s2 += found
    # return 1- , since this thing gives 0 to perfect matches etc
    return 1.0-normalized_damerau_levenshtein_distance(s1, s2)

def calc_dld(gold_triples, pred_triples):
    total_score = 0
    for i, triplist in enumerate(pred_triples):
        total_score += norm_dld(triplist, gold_triples[i])
    avg_score = total_score / len(pred_triples)
    print("avg score:", avg_score)
    return avg_score

if __name__ == '__main__':
    argparser = argparse.ArgumentParser()
    argparser.add_argument('gold_file')
    argparser.add_argument('pred_file')
    args = argparser.parse_args()
    gold_triples, pred_triples = map(
        get_triples, (args.gold_file, args.pred_file))
    assert len(gold_triples) == len(pred_triples), \
        "len(gold) = {}, len(pred) = {}".format(
            len(gold_triples), len(pred_triples))
    calc_precrec(gold_triples, pred_triples)
    calc_dld(gold_triples, pred_triples)
