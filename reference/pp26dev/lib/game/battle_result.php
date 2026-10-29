<?php

/**
 * Pure decider for WHO WON a Battle — no DB, no IO.
 *
 * §11: "The owner whose team covers the point spread wins the Battle." Arithmetic, not
 * judgment, which is why settling is not a Commissioner form.
 *
 * SPREAD CONVENTION — the part that is easy to get backwards. `spread` is quoted from the
 * HOME side, CFBD's convention, and NEGATIVE means home is favored, so a home team favored
 * by 3 carries spread = -3.0 and covers only by winning by MORE than 3:
 *
 * home_points + spread  > away_points home covers
 * home_points + spread  < away_points away covers
 * home_points + spread === away_points     PUSH
 *
 * A push refunds both stakes, and the House takes NO cut: its fee is a cut of a pot that
 * gets paid out, and here none is.
 *
 * NO LINE — CFBD quotes no spread for plenty of games. §11 does not say what happens, and
 * Spencer ruled STRAIGHT UP, the team that scored more, as the only reading that does not
 * invent a number.
 *
 * A tie is a push. FBS overtime means regulation ties do not reach a final score, so this is
 * defensive — but silently picking a winner from equal scores is worse than refunding.
 *
 * Returns ['result' => 'home'|'away'|'push', 'margin' => float, 'basis' => string]
 * where `basis` is the human sentence recorded on the battle row.
 */
function decide_battle_result(?float $spread, int $homePoints, int $awayPoints, string $home = 'Home', string $away = 'Away'): array
{
    $score = sprintf('%s %d–%d %s', $away, $awayPoints, $homePoints, $home);

    if ($spread === null) {
        // Straight up: no line was ever quoted, so there is nothing to cover.
        $margin = (float) ($homePoints - $awayPoints);
        $result = $margin > 0 ? 'home' : ($margin < 0 ? 'away' : 'push');
        return [
                   'result' => $result,
                   'margin' => $margin,
                   'basis'  => $result === 'push'
                       ? "{$score} — tied with no line quoted, so the Battle is a push"
                       : "{$score} — no line quoted, settled straight up",
               ];
    }

    // Positive: home covered by this much. Negative: away did. Zero: push.
    $margin = round($homePoints + $spread - $awayPoints, 1);
    $line = sprintf('%s %+.1f', $home, $spread);

    if (abs($margin) < 0.001) {
        return ['result' => 'push', 'margin' => 0.0,
                       'basis' => "{$score} — landed exactly on {$line}, so the Battle is a push"];
    }

    return [
           'result' => $margin > 0 ? 'home' : 'away',
           'margin' => $margin,
           'basis'  => sprintf('%s — %s covered %s by %.1f', $score,
               $margin > 0 ? $home : $away, $line, abs($margin)),
       ];
}
