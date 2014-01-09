(** Parallel *)

(** Invoke function in a forked process and return result *)
val invoke : ('a -> 'b) -> 'a -> unit -> 'b

(** Launch function for each element of the list in the forked process.
  Does not wait for children to finish - returns immediately. *)
val launch_forks : ('a -> unit) -> 'a list -> unit

(** Launch forks for each element of the list and wait for all workers to finish. Pass exit signals to the workers. *)
val run_forks : ('a -> unit) -> 'a list -> unit

module Thread : sig
type 'a t
val detach : ('a -> 'b) -> 'a -> 'b t
val join : 'a t -> 'a Exn.result
val join_exn : 'a t -> 'a

(** parallel Array.map *)
val map : ('a -> 'b) -> 'a array -> 'b array
(** parallel map with the specified number of workers, default=8 *)
val mapn : ?n:int -> ('a -> 'b) -> 'a list -> 'b Exn.result list
end

module type WorkerT = sig 
  type task 
  type result 
end

module type Workers = sig
type task
type result
type t
(** [create f n] starts [n] parallel workers waiting for tasks *)
val create : (task -> result) -> int -> t
(** [perform workers tasks f] distributes [tasks] to all [workers] in parallel,
    collecting results with [f] and returns when all [tasks] are finished *)
val perform : t -> task Enum.t -> (result -> unit) -> unit
(** [stop ?wait workers] kills worker processes with SIGTERM
  is [wait] is specified it will wait for at most [wait] seconds before killing with SIGKILL,
  otherwise it will wait indefinitely *)
val stop : ?wait:int -> t -> unit
end

(*
val create : ('a -> 'b) -> int -> ('a,'b) t
val perform : ('a,'b) t -> 'a Enum.t -> ('b -> unit) -> unit
*)

(** Thread workers *)
module Threads(T:WorkerT) : Workers
  with type task = T.task
   and type result = T.result 

(** Forked workers *)
module Forks(T:WorkerT) : Workers
  with type task = T.task
   and type result = T.result

module ThreadPool : sig
type t
val create : int -> t
val status : t -> string
val put : t -> (unit -> unit) -> unit
val wait_blocked : ?n:int -> t -> unit
end

(**
 Some callbacks must be executed in the same thread.
 E.g.:
 - libevent loop running in that thread
 - httpev replying to client may need to add new event
 - libevent doesn't provide the facility to break loop from another thread

 So here is a separate queue to store results from ThreadPool for
 subsequent execution on main thread.
*)
module Fin : sig
type t
val setup : Libevent.event_base -> t
val callback : t -> ('a -> unit) -> 'a -> unit

(** Execute [f x] in ThreadPool [pool] and invoke [k result] back in originating thread.
   [result] is either [f x] or [default] if [f] throws an exception.
   Name poolback is a pun on 'execute in pool and callback' *)
val poolback : t -> ThreadPool.t -> 'a -> ('b -> 'a) -> 'b -> ('a -> unit) -> unit
end
