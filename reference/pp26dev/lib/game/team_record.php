<?php

/**
 * Pure decider for one team's season record — no DB, no IO.
 *
 * $team    — the team's name, as `games` spells it.
 * $games   — its COMPLETED games: ['home_team','away_team','home_points','away_points',
 *            'spread','season_type','notes'].
 * $confOf  — lowercased team name => conference, from the league's `teams` rows. An opponent
 *            missing from it (FCS) counts toward the overall record only.
 *
 * Against the spread goes through decide_battle_result(), the function that settles Battles,
 * so this page and a Battle cannot disagree about the sign of a line. A game with no line has
 * no cover: it is left out of the ATS record rather than scored straight up.
 *
 * A conference championship is played between conference rivals and is NOT part of the
 * conference record. CFBD marks one only in `notes`, and only sometimes, so this is
 * best-effort: an unmarked championship game counts as a conference game.
 *
 * Returns ['w','l','conf_w','conf_l','ats_w','ats_l','ats_p',
 *          'rows' => [ ['result' => 'W'|'L'|'T', 'ats' => 'covered'|'missed'|'push'|null], … ]]
 * with `rows` in the order given.
 */
function decide_team_record(string $team, array $games, array $confOf): array
{
    $out = ['w' => 0, 'l' => 0, 'conf_w' => 0, 'conf_l' => 0,
            'ats_w' => 0, 'ats_l' => 0, 'ats_p' => 0, 'rows' => []];
    $me = strtolower($team);
    $myConf = $confOf[$me] ?? null;

    foreach ($games as $g) {
        $isHome = strtolower((string) $g['home_team']) === $me;
        $hp = (int) $g['home_points'];
        $ap = (int) $g['away_points'];
        $diff = $isHome ? $hp - $ap : $ap - $hp;
        $result = $diff > 0 ? 'W' : ($diff < 0 ? 'L' : 'T');

        if ($result !== 'T') {
            $out[$result === 'W' ? 'w' : 'l']++;

            $opp = strtolower((string) ($isHome ? $g['away_team'] : $g['home_team']));
            $inConference = $myConf !== null && $myConf !== 'FBS Independents'
                && ($confOf[$opp] ?? null) === $myConf
                && ($g['season_type'] ?? 'regular') === 'regular'
                && stripos((string) ($g['notes'] ?? ''), 'championship') === false;
            if ($inConference) {
                $out[$result === 'W' ? 'conf_w' : 'conf_l']++;
            }
        }

        $ats = null;
        if ($g['spread'] !== null) {
            $side = decide_battle_result((float) $g['spread'], $hp, $ap)['result'];
            $ats = $side === 'push' ? 'push'
                : (($side === 'home') === $isHome ? 'covered' : 'missed');
            $out[['covered' => 'ats_w', 'missed' => 'ats_l', 'push' => 'ats_p'][$ats]]++;
        }

        $out['rows'][] = ['result' => $result, 'ats' => $ats];
    }
    return $out;
}
