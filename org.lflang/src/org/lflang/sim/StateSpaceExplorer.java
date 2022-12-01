/**
 * Explores the state space of an LF program.
 */
package org.lflang.sim;

import java.util.ArrayList;
import java.util.PriorityQueue;
import java.util.Set;

import org.lflang.TimeUnit;
import org.lflang.TimeValue;

import org.lflang.generator.ActionInstance;
import org.lflang.generator.PortInstance;
import org.lflang.generator.ReactionInstance;
import org.lflang.generator.ReactorInstance;
import org.lflang.generator.RuntimeRange;
import org.lflang.generator.SendRange;
import org.lflang.generator.TimerInstance;
import org.lflang.generator.TriggerInstance;

import org.lflang.lf.Expression;
import org.lflang.lf.Time;
import org.lflang.lf.Variable;

public class StateSpaceExplorer {

    // Instantiate an empty state space diagram.
    public StateSpaceDiagram diagram = new StateSpaceDiagram();

    // Indicate whether a back loop is found in the state space.
    // A back loop suggests periodic behavior.
    public boolean loopFound = false;

    /**
     * Instantiate a global event queue.
     * We will use this event queue to symbolically simulate
     * the logical timeline. This simulation is also valid
     * for runtime implementations that are federated or relax
     * global barrier synchronization, since an LF program
     * defines a unique logical timeline (assuming all reactions
     * behave _consistently_ throughout the execution).
     */
    public PriorityQueue<Event> eventQ = new PriorityQueue<Event>();

    /**
     * The main reactor instance based on which the state space
     * is explored.
     */
    public ReactorInstance main;

    // Constructor
    public StateSpaceExplorer(ReactorInstance main) {
        this.main = main;
    }

    /**
     * Recursively add the first events to the event queue.
     */
    public void addInitialEvents(ReactorInstance reactor) {
        // Add the startup trigger, if exists.
        var startup = reactor.getStartupTrigger();
        if (startup != null) {
            eventQ.add(new Event(startup, new Tag(0, 0, false)));
        }

        // Add the initial timer firings, if exist.
        for (TimerInstance timer : reactor.timers) {
            eventQ.add(
                new Event(
                    timer,
                    new Tag(timer.getOffset().toNanoSeconds(), 0, false)
                )
            );
        }

        // Recursion
        for (var child : reactor.children) {
            addInitialEvents(child);
        }
    } 

    /**
     * Explore the state space and populate the state space diagram
     * until the specified horizon (i.e. the end tag) is reached
     * OR until the event queue is empty.
     * 
     * As an optimization, if findLoop is true, the algorithm
     * tries to find a loop in the state space during exploration.
     * If a loop is found (i.e. a previously encountered state
     * is reached again) during exploration, the function returns early.
     * 
     * TODOs:
     * 1. Handle action with 0 min delay.
     * 2. Check if zero-delay connection works.
     */
    public void explore(Tag horizon, boolean findLoop) {
        // Traverse the main reactor instance recursively to find
        // the known initial events (startup and timers' first firings).
        // FIXME: It seems that we need to handle shutdown triggers 
        // separately, because they could break the back loop.
        addInitialEvents(this.main);
        System.out.println(this.eventQ);
        
        Tag             previous_tag = null; // Tag in the previous loop ITERATION
        Tag             current_tag  = null;  // Tag in the current  loop ITERATION
        StateSpaceNode  current_node = null;
        boolean         stop         = true;
        if (this.eventQ.size() > 0) {
            stop = false;
            current_tag = (eventQ.peek()).tag;
            // System.out.println(current_tag);
        }

        // A list of reactions invoked at the current logical tag
        ArrayList<ReactionInstance> reactions_invoked;
        // A temporary list of reactions processed in the current LOOP ITERATION
        ArrayList<ReactionInstance> reactions_temp;

        while (!stop) {
            // Pop the events from the earliest tag off the event queue.
            ArrayList<Event> current_events = new ArrayList<Event>();
            // FIXME: Use stream methods here?
            while (eventQ.size() > 0 && eventQ.peek().tag.compareTo(current_tag) == 0) {
                Event e = eventQ.poll();
                current_events.add(e);
                // System.out.println("Adding event to current_events: " + e);
            }
            System.out.println(current_events);

            // Collect all the reactions invoked in this current LOOP ITERATION
            // triggered by the earliest events.
            reactions_temp = new ArrayList<ReactionInstance>();
            for (Event e : current_events) {
                Set<ReactionInstance> dependent_reactions
                    = e.trigger.getDependentReactions();
                // System.out.println("Dependent reactions:");
                // for (ReactionInstance reaction : dependent_reactions)
                //     System.out.println(reaction);
                // System.out.println(dependent_reactions);
                reactions_temp.addAll(dependent_reactions);

                // If the event is a timer firing, enqueue the next firing.
                if (e.trigger instanceof TimerInstance) {
                    TimerInstance timer = (TimerInstance) e.trigger;
                    eventQ.add(new Event(
                        timer,
                        new Tag(
                            current_tag.timestamp + timer.getPeriod().toNanoSeconds(),
                            0, // A time advancement resets microstep to 0.
                            false
                        ))
                    );
                }
            }

            // For each reaction invoked, compute the new events produced.
            for (ReactionInstance reaction : reactions_temp) {
                // Iterate over all the effects produced by this reaction.
                // If the effect is a port, obtain the downstream port along
                // a connection and enqueue a future event for that port.
                // If the effect is an action, enqueue a future event for
                // this action.
                for (TriggerInstance<? extends Variable> effect : reaction.effects) {
                    if (effect instanceof PortInstance) {

                        // System.out.println("Effect: " + effect);
                        // System.out.print("Eventual destinations: ");
                        // System.out.println(((PortInstance)effect).getDependentPorts());
                        
                        for (SendRange senderRange
                                : ((PortInstance)effect).getDependentPorts()) {

                            // System.out.print("Sender range: ");
                            // System.out.println(senderRange.destinations);

                            for (RuntimeRange<PortInstance> destinationRange
                                    : senderRange.destinations) {
                                PortInstance downstreamPort = destinationRange.instance;
                                // System.out.println("Located a destination port: " + downstreamPort);

                                // Getting delay from connection
                                // FIXME: Is there a more concise way to do this?
                                long delay = 0;
                                Expression delayExpr = senderRange.connection.getDelay();
                                if (delayExpr instanceof Time) {
                                    long interval = ((Time) delayExpr).getInterval();
                                    String unit = ((Time) delayExpr).getUnit();
                                    TimeValue timeValue = new TimeValue(interval, TimeUnit.fromName(unit));
                                    delay = timeValue.toNanoSeconds();
                                }

                                // Create and enqueue a new event.
                                Event e = new Event(
                                    downstreamPort,
                                    new Tag(current_tag.timestamp + delay, 0, false)
                                );
                                eventQ.add(e);
                            }
                        }
                    }
                    else if (effect instanceof ActionInstance) {
                        // Get the minimum delay of this action.
                        long min_delay = ((ActionInstance)effect).getMinDelay().toNanoSeconds();
                        // Create and enqueue a new event.
                        Event e = new Event(
                            effect,
                            new Tag(current_tag.timestamp + min_delay, 0, false)
                        );
                        eventQ.add(e);
                    }
                }
            }

            // When we first advance to a new tag, create a new node in the state space diagram.
            if (
                previous_tag == null // The first iteration
                || current_tag.compareTo(previous_tag) > 0
            ) {
                // Copy the reactions in reactions_temp.
                reactions_invoked = new ArrayList<ReactionInstance>(reactions_temp);

                // Create a new state in the SSD for the current tag,
                // add the reactions triggered to the state,
                // and add a snapshot of the event queue (with new events
                // generated by reaction invocations in the curren tag)
                // to the state.
                StateSpaceNode node = new StateSpaceNode(
                    current_tag,                    // Current tag
                    reactions_invoked,              // Reactions invoked at this tag
                    new ArrayList<Event>(eventQ)    // A snapshot of the event queue
                );

                // If findLoop is true, check for loops.
                // FIXME: For some reason, the below doesn't work.
                // if (findLoop && diagram.hasNode(node)) {
                if (findLoop) {
                    for (StateSpaceNode n : diagram.nodes()) {
                        if (n.equals(node)) {
                            loopFound = true;
                            System.out.println("*** A loop is found!");
                            // Mark the loop in the diagram.
                            this.diagram.loopNode = n;
                            this.diagram.tail = current_node;
                            this.diagram.loopPeriod = current_tag.timestamp
                                                        - this.diagram.loopNode.tag.timestamp;
                            this.diagram.addEdge(this.diagram.loopNode, this.diagram.tail);
                            return; // Exit the while loop early.
                        }
                    }
                } 

                // Add the new node to the state space diagram.
                this.diagram.addNode(node);
                System.out.println("Adding a new node to the diagram.");
                node.display();
                
                // If the head is not empty, add an edge from the previous state
                // to the next state. Otherwise initialize the head to the new node.
                if (this.diagram.head != null && current_node != null) {
                    // System.out.println("--- Add a new edge between " + current_node + " and " + node);
                    this.diagram.addEdge(node, current_node); // Sink first, then source
                }
                else
                    this.diagram.head = node; // Initialize the head.
                
                // Update the current node.
                current_node = node;
            }
            // Time does not advance because we are processing
            // connections with zero delay.
            else {
                // Add reactions explored in the current loop iteration
                // to the existing state space node.
                current_node.reactions_invoked.addAll(reactions_temp);
            }

            // Update the current tag for the next iteration.
            if (eventQ.size() > 0) {
                previous_tag = current_tag;
                current_tag = eventQ.peek().tag;
            }

            // Stop if:
            // 1. the event queue is empty, or
            // 2. the horizon is reached.
            if (eventQ.size() == 0 
                || current_tag.compareTo(horizon) > 0)
                stop = true;
        }
        return;
    }
}