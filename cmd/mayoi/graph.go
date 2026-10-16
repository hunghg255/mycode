package main

import "mayoi/internal/git"

// graphLane is a lane of the history's graph between two rows: the commit
// it leads down to, "" while free, and its color.
type graphLane struct {
	hash  string
	color int
}

// graphRow is the graph of a row of the history. Above is the lanes at
// the row's top edge, below those at its bottom edge, each in its place;
// the commit's dot is in lane at the middle. A lane above that leads to
// the commit joins the dot, as do those below that lead to its parents
// (from), and the others run straight through.
type graphRow struct {
	lane, color  int
	above, below []graphLane
	from         []bool // by lane below: whether it starts at the dot
	merge        bool
}

// width is how many lanes the row has, at either edge.
func (r *graphRow) width() int { return max(len(r.above), len(r.below), r.lane+1) }

// layoutGraph lays out the lanes of commits, newest first and each after
// the commits made on it: each commit takes the lane that leads to it,
// or a new one, which it hands to its first parent; its other parents
// take lanes of their own unless one leads to them already. Lanes freed
// are taken again from the left, and each new lane takes the next color.
func layoutGraph(cs []git.Commit) []graphRow {
	rows := make([]graphRow, len(cs))
	var lanes []graphLane
	colors := 0
	free := func() int {
		for i, l := range lanes {
			if l.hash == "" {
				return i
			}
		}
		lanes = append(lanes, graphLane{})
		return len(lanes) - 1
	}
	trim := func() {
		for len(lanes) > 0 && lanes[len(lanes)-1].hash == "" {
			lanes = lanes[:len(lanes)-1]
		}
	}
	for k := range cs {
		c := &cs[k]
		row := &rows[k]
		row.above = append([]graphLane(nil), lanes...)
		row.merge = len(c.Parents) > 1
		node := -1
		for i, l := range lanes {
			if l.hash != c.Hash {
				continue
			}
			if node < 0 {
				node = i
			} else {
				lanes[i].hash = ""
			}
		}
		if node < 0 {
			node = free()
			lanes[node] = graphLane{hash: c.Hash, color: colors}
			colors++
		}
		row.lane, row.color = node, lanes[node].color
		var from []int
		if len(c.Parents) == 0 {
			lanes[node].hash = ""
		} else {
			lanes[node].hash = c.Parents[0]
			from = append(from, node)
		}
		for _, p := range c.Parents[min(1, len(c.Parents)):] {
			at := -1
			for i, l := range lanes {
				if l.hash == p {
					at = i
					break
				}
			}
			if at < 0 {
				at = free()
				lanes[at] = graphLane{hash: p, color: colors}
				colors++
			}
			from = append(from, at)
		}
		trim()
		row.below = append([]graphLane(nil), lanes...)
		row.from = make([]bool, len(lanes))
		for _, i := range from {
			row.from[i] = true
		}
	}
	return rows
}

// graphLanes is how many lanes the graph of rows shows at most.
func graphLanes(rows []graphRow) int {
	n := 1
	for i := range rows {
		n = max(n, rows[i].width())
	}
	return n
}
