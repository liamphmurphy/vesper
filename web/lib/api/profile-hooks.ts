"use client";

// ---- Your profile: name, role title and picture (GET/PATCH /me, PUT/DELETE /me/avatar).
// Every change refreshes the bootstrap query, which carries `me` and `users` for the whole shell.

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, postForm, unwrap, type Schemas } from "./client";

export type Profile = Schemas["User"];
export type ProfilePatch = Schemas["ProfilePatch"];

export const profileKeys = { me: ["profile"] as const };

/** The saved profile goes straight into the cache; bootstrap refetches for the sidebar and pickers. */
function useProfileDone() {
  const qc = useQueryClient();
  return {
    saved: (p: Profile) => qc.setQueryData(profileKeys.me, p),
    settled: () =>
      Promise.all([
        qc.invalidateQueries({ queryKey: profileKeys.me }),
        qc.invalidateQueries({ queryKey: ["bootstrap"] }),
      ]),
  };
}

/** A 422 carries the offending `field`. */
export function useUpdateProfile() {
  const { saved, settled } = useProfileDone();
  return useMutation({
    mutationFn: (body: ProfilePatch) => unwrap(api.PATCH("/me", { body })),
    onSuccess: saved,
    onSettled: settled,
  });
}

/** Multipart PUT; the server sniffs the bytes (413 too large, 415 wrong type, 422 empty). */
export function useUploadProfileAvatar() {
  const { saved, settled } = useProfileDone();
  return useMutation({
    mutationFn: (file: File) => {
      const form = new FormData();
      form.append("file", file);
      return postForm<Profile>("/me/avatar", form, "PUT");
    },
    onSuccess: saved,
    onSettled: settled,
  });
}

export function useDeleteProfileAvatar() {
  const { saved, settled } = useProfileDone();
  return useMutation({
    mutationFn: () => unwrap(api.DELETE("/me/avatar")),
    onSuccess: saved,
    onSettled: settled,
  });
}
