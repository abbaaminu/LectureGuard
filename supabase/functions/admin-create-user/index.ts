import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const jsonResponse = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Required Supabase function secrets are not configured.");
    return jsonResponse(500, { error: "Staff account service is misconfigured." });
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return jsonResponse(401, { error: "Sign in as an administrator." });
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = authorization.slice("Bearer ".length);
  const { data: userData, error: userError } =
    await authClient.auth.getUser(token);
  if (userError || !userData.user) {
    return jsonResponse(401, { error: "The sign-in token is invalid or expired." });
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: callerProfile, error: profileError } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", userData.user.id)
    .maybeSingle();
  if (profileError) {
    console.error("Could not verify the caller's profile role:", profileError.message);
    return jsonResponse(500, { error: "Could not verify administrator access." });
  }
  if (callerProfile?.role !== "admin") {
    return jsonResponse(403, { error: "Only administrators can create staff logins." });
  }

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = await request.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return jsonResponse(400, { error: "Expected a JSON object." });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return jsonResponse(400, { error: "Request body must be valid JSON." });
  }

  const email = typeof body.email === "string" ? body.email.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const role = body.role;
  const fullName =
    typeof body.full_name === "string" ? body.full_name.trim() : "";
  const department =
    typeof body.department === "string" ? body.department.trim() : "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return jsonResponse(400, { error: "Enter a valid email address." });
  }
  if (password.length < 12) {
    return jsonResponse(400, { error: "Password must be at least 12 characters." });
  }
  if (role !== "teacher" && role !== "admin") {
    return jsonResponse(400, { error: "Role must be teacher or admin." });
  }

  const resolvedName = fullName || email.split("@")[0];
  const { data: created, error: createError } =
    await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: resolvedName },
      app_metadata: { role },
    });
  if (createError || !created.user) {
    return jsonResponse(400, {
      error: createError?.message ?? "Could not create the Auth user.",
    });
  }

  const { data: profile, error: upsertError } = await adminClient
    .from("profiles")
    .upsert(
      {
        id: created.user.id,
        full_name: resolvedName,
        email,
        role,
        department: department || null,
      },
      { onConflict: "id" },
    )
    .select("id, full_name, email, role, department")
    .single();
  if (upsertError || !profile) {
    const { error: cleanupError } = await adminClient.auth.admin.deleteUser(
      created.user.id,
    );
    if (cleanupError) {
      console.error("Failed to clean up Auth user after profile provisioning error:", cleanupError.message);
    }
    console.error("Could not provision staff profile:", upsertError?.message);
    return jsonResponse(500, { error: "Auth user was created but profile provisioning failed." });
  }

  return jsonResponse(201, profile);
});
