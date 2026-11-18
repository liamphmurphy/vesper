// The Learn study view's left column (learn/_components/study-view.tsx): the course, its next
// part and its lessons by unit.
import type { NavItem, NavModel } from "../protocol.ts";

export const STUDY_NAV_ID = "study";
export const STUDY_BACK = "back";
export const STUDY_DELETE = "delete";
export const STUDY_PLAN_NEXT = "plan-next";
export const STUDY_STOP_BUILD = "stop-build";

export interface StudyLesson {
  key: string;
  title: string;
  unit: string;
  /** Started or finished, or already known. */
  done: boolean;
  status: string;
}

export interface StudyNextPart {
  /** 1-based part in question and the total. */
  part: number;
  parts: number;
  title?: string;
  /** The course's state: ready, scoping, outline_ready or a building state. */
  state: string;
  building: boolean;
  error?: string | null;
  buildNote?: string | null;
  planPending: boolean;
  stopPending: boolean;
  actionError?: string | null;
  courseId: string;
}

export function buildStudyNavModel(input: {
  topic: string;
  complete: number;
  total: number;
  solid: number;
  nextPart?: StudyNextPart | null;
  lessons: readonly StudyLesson[];
  currentKey?: string;
  courseId: string;
}): NavModel {
  const sections: NavModel["sections"] = [
    { id: "progress", items: [{ id: "progress", title: `${input.complete} of ${input.total} complete · ${input.solid} solid`, disabled: true }] },
  ];
  const np = input.nextPart;
  if (np) {
    const items: NavItem[] = [];
    if (np.state === "ready") {
      items.push({
        id: STUDY_PLAN_NEXT,
        title: np.planPending ? "Starting…" : `Plan part ${np.part} now`,
        subtitle: np.error ? `${np.error} · Its outline starts on its own when you reach the last unit.` : "Its outline starts on its own when you reach the last unit.",
        icon: "play",
        disabled: np.planPending,
      });
    } else if (np.state === "scoping") {
      items.push({ id: "scoping", title: "Drafting its outline from how you’re doing…", disabled: true });
    } else if (np.state === "outline_ready") {
      items.push({ id: "review", title: "Review its outline", icon: "edit", href: `/learn/${np.courseId}?review=1` });
    }
    if (np.building && np.state !== "scoping") {
      items.push({ id: "building", title: `Building${np.buildNote ? ` · ${np.buildNote}` : ""}. Keep studying meanwhile.`, disabled: true });
    }
    if (np.building) items.push({ id: STUDY_STOP_BUILD, title: "Stop building it", icon: "pause", disabled: np.stopPending });
    if (np.actionError) items.push({ id: "next-error", title: np.actionError, status: "blocked", disabled: true });
    sections.push({ id: "next-part", title: `Part ${np.part} of ${np.parts}${np.title ? ` · ${np.title}` : ""}`, items });
  }
  const units = [...new Set(input.lessons.map((l) => l.unit))];
  for (const u of units) {
    sections.push({
      id: `unit:${u}`,
      title: u,
      items: input.lessons
        .filter((l) => l.unit === u)
        .map((l) => {
          const item: NavItem = { id: l.key, title: l.title };
          if (l.done) item.icon = "check";
          if (l.status === "flagged") {
            item.status = "human";
            item.subtitle = "Flagged: see reviewer note";
          }
          if (l.status === "known") {
            item.subtitle = "You know this";
            item.disabled = true;
          }
          return item;
        }),
    });
  }
  return {
    id: STUDY_NAV_ID,
    title: input.topic,
    actions: [
      { id: STUDY_BACK, label: "Back to Learn", icon: "chev" },
      { id: STUDY_DELETE, label: "Delete course", icon: "trash" },
    ],
    sections,
    selectedId: input.currentKey ?? null,
  };
}
